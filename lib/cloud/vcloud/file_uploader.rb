module VCloudCloud
  class FileUploader
    class << self
      def upload(href, size, stream, options = {})
        request = create_request(href, size, stream, options)
        net = create_connection(href)
        net.start do |http|
          response = http.request(request) { |http_response| http_response.read_body }
          raise "Error Response: #{response.code} #{response.body}" if response.code.to_i >= 400
          response
        end
      end

      private

      def create_request(href, size, stream, options = {})
        http_method = options[:method] || :Put
        headers = {}
        headers['Content-Type'] = options[:content_type] if options[:content_type]
        headers['X-VCloud-Authorization'] = options[:authorization] if options[:authorization]
        headers['Cookie'] = options[:cookie].map { |k, v| "#{k.to_s}=#{CGI::unescape(v)}" }.sort.join(';') if options[:cookie]
        headers['Content-Length'] = size.to_s
        headers['Transfer-Encoding'] = 'chunked'
        request_type = Net::HTTP.const_get(http_method)
        request = request_type.new(href, headers)
        request.body_stream = stream
        request
      end

      def create_connection(href)
        uri = URI::parse(href)
        proxy_address, proxy_port = NetHttpHelper.new.http_proxy(uri)

        net = Net::HTTP.new(uri.host, uri.port, proxy_address, proxy_port, nil, nil)
        net.use_ssl = uri.is_a?(URI::HTTPS)
        net.verify_mode = OpenSSL::SSL::VERIFY_NONE if net.use_ssl?
        net
      end
    end
  end

  class NetHttpHelper

    # Fetches for ENV variables the http proxies coordinates and
    # Returns proxy adress and port expected by Net::HTTP.start
    def http_proxy(uri)
      if uri.scheme == 'https'
        proxy = ENV['https_proxy']
      else
        proxy = ENV['http_proxy']
      end
      proxy_uri = URI.parse(proxy) unless proxy.nil?
      if proxy_uri
        proxy_address = proxy_uri.hostname
        proxy_port = proxy_uri.port
      else
        proxy_address = nil
        proxy_port = nil
      end
      return proxy_address, proxy_port
    end
  end
end
