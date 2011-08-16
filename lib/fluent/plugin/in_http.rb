#
# Fluent
#
# Copyright (C) 2011 FURUHASHI Sadayuki
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
#
module Fluent


class HttpInput < Input
  Plugin.register_input('http', self)

  require 'http/parser'

  def initialize
    require 'webrick/httputils'
    @port = 9880
    @bind = '0.0.0.0'
    @body_size_limit = 32*1024*1024  # TODO default
  end

  def configure(conf)
    @port = conf['port'] || @port
    @port = @port.to_i

    @bind = conf['bind'] || @bind

    if body_size_limit = conf['body_size_limit']
      @body_size_limit = Config.size_value(body_size_limit)
    end
  end

  # TODO multithreading
  def start
    $log.debug "listening http on #{@bind}:#{@port}"
    @loop = Coolio::Loop.new
    @lsock = Coolio::TCPServer.new(@bind, @port, Handler, method(:on_request), @body_size_limit)
    @loop.attach(@lsock)
    @thread = Thread.new(&method(:run))
  end

  def shutdown
    @lsock.close
    @loop.stop
    #@thread.join  # TODO
  end

  def run
    @loop.run
  rescue
    $log.error "unexpected error", :error=>$!.to_s
    $log.error_backtrace
  end

  def on_request(path_info, params)
    begin
      path = path_info[1..-1]  # remove /
      tag = path.split('/').join('.')

      if msgpack = params['msgpack']
        record = MessagePack.unpack(msgpack)

      elsif js = params['json']
        record = JSON.parse(js)

      else
        raise "'json' or 'msgpack' parameter is required"
      end

      time = params['time']
      time = time.to_i
      if time == 0
        time = Engine.now
      end

      event = Event.new(time, record)

    rescue
      return ["400 Bad Request", {'Content-type'=>'text/plain'}, "400 Bad Request\n#{$!}\n"]
    end

    # TODO server error
    begin
      Engine.emit(tag, event)
    rescue
      return ["500 Internal Server Error", {'Content-type'=>'text/plain'}, "500 Internal Server Error\n#{$!}\n"]
    end

    return ["200 OK", {'Content-type'=>'text/plain'}, ""]
  end

  class Handler < Coolio::Socket
    def initialize(io, callback, body_size_limit)
      super(io)
      @callback = callback
      @body_size_limit = body_size_limit
      @content_type = ""
      @next_close = false
    end

    def on_connect
      @parser = Http::Parser.new(self)
    end

    def on_read(data)
      @parser << data
    rescue
      $log.warn "unexpected error", :error=>$!.to_s
      $log.warn_backtrace
    end

    def on_message_begin
      @body = ''
    end

    def on_headers_complete(headers)
      expect = nil
      size = nil
      headers.each_pair {|k,v|
        case k
        when /Expect/i
          expect = v
        when /Content-Length/i
          size = v.to_i
        when /Content-Type/i
          @content_type = v
        end
      }
      if expect
        if expect == '100-continue'
          if !size || size < @body_size_limit
            send_response_nobody("100 Continue", {})
          else
            send_response_and_close("413 Request Entity Too Large", {}, "Too large")
          end
        else
          send_response_and_close("417 Expectation Failed", {}, "")
        end
      end
    end

    def on_body(chunk)
      if @body.bytesize + chunk.bytesize > @body_size_limit
        unless closing?
          send_response_and_close("413 Request Entity Too Large", {}, "Too large")
        end
        return
      end
      @body << chunk
    end

    def on_message_complete
      return if closing?

      params = WEBrick::HTTPUtils.parse_query(@parser.query_string)

      if @content_type =~ /^application\/x-www-form-urlencoded/
        params.update WEBrick::HTTPUtils.parse_query(@body)
      elsif @content_type =~ /^multipart\/form-data; boundary=(.+)/
        boundary = WEBrick::HTTPUtils.dequote($1)
        params.update WEBrick::HTTPUtils.parse_form_data(@body, boundary)
      end
      path_info = @parser.request_path

      code, header, body = *@callback.call(path_info, params)
      body = body.to_s

      # TODO keepalive
      send_response_and_close(code, header, body)
    end

    def on_write_complete
      close if @next_close # TODO keepalive
    end

    def send_response_and_close(code, headers, body)
      send_response(code, headers, body)
      @next_close = true
    end

    def closing?
      @next_close
    end

    def send_response(code, header, body)
      header['Content-length'] ||= body.bytesize
      header['Content-type'] ||= 'text/plain'

      data = %[HTTP/1.1 #{code}\r\n]
      header.each_pair {|k,v|
        data << "#{k}: #{v}\r\n"
      }
      data << "\r\n"
      write data

      write body
    end

    def send_response_nobody(code, header)
      data = %[HTTP/1.1 #{code}\r\n]
      header.each_pair {|k,v|
        data << "#{k}: #{v}\r\n"
      }
      data << "\r\n"
      write data
    end
  end
end


end

