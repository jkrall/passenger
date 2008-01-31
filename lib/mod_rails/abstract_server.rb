require 'socket'
require 'mod_rails/message_channel'
require 'mod_rails/utils'
require 'mod_rails/core_extensions'
module ModRails # :nodoc:

# An abstract base class for a server, with the following properties:
#
#  - The server has exactly one client, and is connected to that client at all times. The server will
#    quit when the connection closes.
#  - The server's main loop is run in a child process (and so is asynchronous from the main process).
#  - One can communicate with the server through discrete messages (as opposed to byte streams).
#  - The server can pass file descriptors (IO objects) back to the client.
#
# A message is just an ordered list of strings. The first element in the message is the _message name_.
#
# The server will also reset all signal handlers (in the child process). That is, it will respond to
# all signals in the default manner. The only exception is SIGHUP, which is ignored.
#
# Before an AbstractServer can be used, it must first be started by calling start(). When it is no
# longer needed, stop() should be called.
#
# Here's an example on using AbstractServer:
#
#  class MyServer < ModRails::AbstractServer
#     def initialize
#        super()
#        define_message_handler(:hello, :handle_hello)
#     end
#
#     def hello(first_name, last_name)
#        send_to_server('hello', first_name, last_name)
#        reply, pointless_number = recv_from_server
#        puts "The server said: #{reply}"
#        puts "In addition, it sent this pointless number: #{pointless_number}"
#     end
#
#  private
#     def handle_hello(first_name, last_name)
#        send_to_client("Hello #{first_name} #{last_name}, how are you?", 1234)
#     end
#  end
#  
#  server = MyServer.new
#  server.start
#  server.hello("Joe", "Dalton")
#  server.stop
class AbstractServer
	include Utils
	SERVER_TERMINATION_SIGNAL = "SIGTERM"

	# Raised when the server receives a message with an unknown message name.
	class UnknownMessage < StandardError
	end
	
	class ServerAlreadyStarted < StandardError
	end
	
	class ServerNotStarted < StandardError
	end
	
	# An array of integers, representing the file descriptors that should be closed in the
	# server's child process. It can also be nil. This is used internally by mod_rails and should
	# not be used directly.
	attr_accessor :file_descriptors_to_close

	def initialize
		@done = false
		@message_handlers = {}
	end
	
	# Start the server. This method does not block since the server runs
	# asynchronously from the current process.
	#
	# You may only call this method if the server is not already started.
	# Otherwise, a ServerAlreadyStarted will be raised.
	def start
		if !@parent_channel.nil?
			raise ServerAlreadyStarted, "Server is already started"
		end
	
		@parent_socket, @child_socket = UNIXSocket.pair
		before_fork
		@pid = fork do
			begin
				@parent_socket.close
				@child_channel = MessageChannel.new(@child_socket)
				close_file_descriptors
				initialize_server
				reset_signal_handlers
				main_loop
				finalize_server
			rescue Exception => e
				print_exception(self.class.to_s, e)
			ensure
				exit!
			end
		end
		@child_socket.close
		@parent_channel = MessageChannel.new(@parent_socket)
	end
	
	# Stop the server. The server will quit as soon as possible. This method waits
	# until the server has been stopped.
	#
	# When calling this method, the server must already be started. If not, a
	# ServerNotStarted will be raised.
	def stop
		if @parent_channel.nil?
			raise ServerNotStarted, "Server is not started"
		end
		
		@parent_socket.close
		@parent_channel = nil
		Process.kill(SERVER_TERMINATION_SIGNAL, @pid) rescue nil
		Process.waitpid(@pid) rescue nil
	end

protected
	# Close the file descriptors, as specified by _file_descriptors_to_close_.
	def close_file_descriptors
		if !file_descriptors_to_close.nil?
			file_descriptors_to_close.each do |fd|
				IO.new(fd, "r").close
			end
		end
	end
	
	# A hook which is called when the server is being started, just before forking a new process.
	# The default implementation does nothing, this method is supposed to be overrided by child classes.
	def before_fork
	end
	
	# A hook which is called when the server is being started. This is called in the child process,
	# before the main loop is entered.
	# The default implementation does nothing, this method is supposed to be overrided by child classes.
	def initialize_server
	end
	
	# A hook which is called when the server is being stopped. This is called in the child process,
	# after the main loop has been left.
	# The default implementation does nothing, this method is supposed to be overrided by child classes.
	def finalize_server
	end
	
	# Define a handler for a message. _message_name_ is the name of the message to handle,
	# and _handler_ is the name of a method to be called (this may either be a String or a Symbol).
	#
	# A message is just a list of strings, and so _handler_ will be called with the message as its
	# arguments, excluding the first element. See also the example in the class description.
	def define_message_handler(message_name, handler)
		@message_handlers[message_name.to_s] = handler
	end
	
	# Send a message to the server. _name_ is the name of the message, and _args_ are optional
	# arguments for the message. Note that all arguments will be turned into strings before they
	# are sent to the server, so you cannot specify complex objects as arguments. Furthermore,
	# all arguments, when stringified, may not contain the character as specified by
	# MessageChannel::DELIMITER.
	#
	# The server must already be started. Otherwise, a ServerNotStarted will be raised.
	# Raises Errno::EPIPE if the server has already closed the connection.
	# Raises IOError if the server connection channel has already been closed on
	# this side (unlikely to happen; AbstractServer never does this except when stop()
	# is called).
	def send_to_server(name, *args)
		if @parent_channel.nil?
			raise ServerNotStarted, "Server hasn't been started yet. Please call start() first."
		end
		@parent_channel.write(name, *args)
	end
	
	# Receive a message from the server. Returns an array of strings, which represents the message.
	# Returns nil if the server has already closed the connection.
	# This method never throws any exceptions.
	def recv_from_server
		return @parent_channel.read
	end
	
	# Receive an IO object from the server. Please search Google on Unix sockets file descriptors
	# passing if you're unfamiliar with this.
	#
	# Raises SocketError if the next item in the server connection stream is not a file descriptor,
	# or if end-of-stream has been reached.
	# Raises IOError if the server connection stream is already closed on this side.
	def recv_io_from_server
		return @parent_channel.recv_io
	end
	
	# Receive a message from the client. Returns an array of strings, which represents the message.
	# Returns nil if the client has already closed the connection.
	# This method never throws any exceptions.
	def recv_from_client
		return @child_channel.read
	end
	
	# Send a message back to the server. _name_ is the name of the message, and _args_ are optional
	# arguments for the message. Note that all arguments will be turned into strings before they
	# are sent to the server, so you cannot specify complex objects as arguments. Furthermore,
	# all arguments, when stringified, may not contain the character as specified by
	# MessageChannel::DELIMITER.
	#
	# Raises Errno::EPIPE if the server has already closed the connection.
	# Raises IOError if the client connection channel has already been closed on
	# this side (unlikely to happen; AbstractServer never does this).
	def send_to_client(name, *args)
		@child_channel.write(name, *args)
	end
	
	# Send an IO object back to the client. Please search Google on Unix sockets file descriptors
	# passing if you're unfamiliar with this.
	#
	# Raises SocketError if the next item in the client connection stream is not a file descriptor,
	# or if end-of-stream has been reached.
	# Raises IOError if the client connection stream is already closed on this side.
	def send_io_to_client(io)
		@child_channel.send_io(io)
	end
	
	# Tell the main loop to stop as soon as possible.
	def quit_main
		@done = true
	end

private
	# Reset all signal handlers to default. This is called in the child process,
	# before entering the main loop.
	def reset_signal_handlers
		Signal.list.each_key do |signal|
			begin
				trap(signal, 'DEFAULT')
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		trap('HUP', 'IGNORE')
	end
	
	# The server's main loop. This is called in the child process.
	# The main loop's main function is to read messages from the socket,
	# and letting registered message handlers handle each message.
	# Use define_message_handler() to register a message handler.
	#
	# If an unknown message is encountered, UnknownMessage will be raised.
	def main_loop
		channel = MessageChannel.new(@child_socket)
		while !@done
			begin
				name, *args = channel.read
				if name.nil?
					@done = true
				elsif @message_handlers.has_key?(name)
					__send__(@message_handlers[name], *args)
				else
					raise UnknownMessage, "Unknown message '#{name}' received."
				end
			rescue SignalException => signal
				if signal.message == SERVER_TERMINATION_SIGNAL
					@done = true
				else
					raise
				end
			end
		end
	end
end

end # module ModRails