#--
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#++

# Tools for tests

require 'minitest/autorun'
require 'qpid_proton'
require 'thread'
require 'socket'

Container = Qpid::Proton::Reactor::Container
MessagingHandler = Qpid::Proton::Handler::MessagingHandler

# Bind an unused local port using bind(0) and SO_REUSEADDR and hold it till close()
# Provides #host, #port and #addr ("host:port") as strings
class TestPort
  attr_reader :host, :port, :addr

  # With block, execute block passing self then close
  # Note host must be the local host, but you can pass '::1' instead for ipv6
  def initialize(host='127.0.0.1')
    @sock = Socket.new(:INET, :STREAM)
    @sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true)
    @sock.bind(Socket.sockaddr_in(0, host))
    @host, @port = @sock.connect_address.ip_unpack
    @addr = "#{@host}:#{@port}"
    if block_given?
      begin
        yield self
      ensure
        close
      end
    end
  end

  def close
    @sock.close()
  end
end

class TestError < Exception; end

# Handler that creates its own container to run itself, and records some common
# events that are checked by tests
class TestHandler < MessagingHandler

  # Record errors and successfully opened endpoints
  attr_reader :errors, :connections, :sessions, :links, :messages

  # Pass optional extra handlers and options to the Container
  def initialize(handlers=[], options={})
    super()
    # Use Queue so the values can be extracted in a thread-safe way during or after a test.
    @errors, @connections, @sessions, @links, @messages = (1..5).collect { Queue.new }
    @container = Container.new([self]+handlers, options)
  end

  # Run the handlers container, return self.
  # Raise an exception for server errors unless no_raise is true.
  def run(no_raise=false)
    @container.run
    raise_errors unless no_raise
    self
  end

  # If the handler has errors, raise a TestError with all the error text
  def raise_errors()
    return if @errors.empty?
    text = ""
    while @errors.size > 0
      text << @errors.pop + "\n"
    end
    raise TestError.new("TestServer has errors:\n #{text}")
  end

  # TODO aconway 2017-08-15: implement in MessagingHandler
  def on_error(event, endpoint)
    @errors.push "#{event.type}: #{endpoint.condition.name}: #{endpoint.condition.description}"
    raise_errors
  end

  def on_transport_error(event)
    on_error(event, event.transport)
  end

  def on_connection_error(event)
    on_error(event, event.condition)
  end

  def on_session_error(event)
    on_error(event, event.session)
  end

  def on_link_error(event)
    on_error(event, event.link)
  end

  def on_opened(queue, endpoint)
    queue.push(endpoint)
    endpoint.open
  end

  def on_connection_opened(event)
    on_opened(@connections, event.connection)
  end

  def on_session_opened(event)
    on_opened(@sessions, event.session)
  end

  def on_link_opened(event)
    on_opened(@links, event.link)
  end

  def on_message(event)
    @messages.push(event.message)
  end
end

# A TestHandler that runs itself in a thread and listens on a TestPort
class TestServer < TestHandler
  attr_reader :host, :port, :addr

  # Pass optional handlers, options to the container
  def initialize(handlers=[], options={})
    super
    @tp = TestPort.new
    @host, @port, @addr = @tp.host, @tp.port, @tp.addr
    @listening = false
    @ready = Queue.new
  end

  # Start server thread
  def start(no_raise=false)
    @thread = Thread.new do
      begin
        @container.listen(addr)
        @container.run
      rescue TestError
        ready.push :error
       rescue => e
        msg = "TestServer run raised: #{e.message}\n#{e.backtrace.join("\n")}"
        @errors << msg
        @ready.push(:error)
        # TODO aconway 2017-08-22: container.stop - doesn't stop the thread.
      end
    end
    raise_errors unless @ready.pop == :listening or no_raise
  end

  # Stop server thread
  def stop(no_raise=false)
    @container.stop
    if not @errors.empty?
      @thread.kill
    else
      @thread.join
    end
    @tp.close
    raise_errors unless no_raise
  end

  # start(), execute block with self, stop()
  def run(no_raise=false)
    begin
      start(no_raise)
      yield self
    ensure
      stop(no_raise)
    end
  end

  def on_start(event)
    @ready.push :listening
    @listening = true
  end
end
