require "spec_helper"

module VCloudCloud
  describe FileUploader do
    let(:upload_link) { "http://fakedomain.com/" }
    let(:size) { 10 }
    let(:stream) do
      stream = double("stream")
      stream
    end

    let(:options) { { cookie: { key: "value" } } }
    let(:request) do
      request = double("http_request")
      request
    end

    let(:connection) do
      connection = double("connection")
      connection.stub(:use_ssl?) { false }
      connection.stub(:use_ssl=)
      connection
    end

    let(:response) do
      response = double("response")
      response.stub(:body) { "body" }
      response
    end

    let(:nethttphelper) {
      nethttphelper = double(NetHttpHelper)
    }

    describe "#upload" do
      it "uploads stream to url" do
        VCloudCloud::NetHttpHelper.should_receive(:new).and_return(nethttphelper)
        nethttphelper.should_receive(:http_proxy).and_return([nil, nil])
        Net::HTTP::Put.stub(:new).with(upload_link, anything) { request }
        Net::HTTP.should_receive(:new).and_return(connection)
        request.stub(:body_stream=).with(stream)
        connection.should_receive(:start).and_yield(connection)
        response.should_receive(:read_body)
        response.should_receive(:code) { "201" }
        connection.should_receive(:request).with(request).
          and_yield(response).and_return(response)

        described_class.upload(upload_link, size, stream, options)
      end

      it "raise error when request failed" do
        Net::HTTP::Put.stub(:new).with(upload_link, anything) { request }
        Net::HTTP.stub(:new) { connection }
        request.stub(:body_stream=).with(stream)
        connection.should_receive(:start).and_yield(connection)
        response.should_receive(:read_body)
        response.should_receive(:code).at_least(2).times { "401" }
        connection.should_receive(:request).with(request).
          and_yield(response).and_return(response)

        expect {
          described_class.upload(upload_link, size, stream, options)
        }.to raise_error /Error Response/

      end
    end
  end

  describe NetHttpHelper do

    describe '#http_proxy' do
      context 'when no proxy defined in ENV' do
        it 'should return nil for http and https urls ' do
          stub_const('ENV', {'http_proxy' => nil, 'https_proxy' => nil})
          proxy_address, proxy_port = subject.http_proxy(URI('https://host/path'))
          expect(proxy_address).to be_nil
          expect(proxy_port).to be_nil

          proxy_address, proxy_port = subject.http_proxy(URI('http://host/path'))
          expect(proxy_address).to be_nil
          expect(proxy_port).to be_nil
        end
      end
      context 'when http_proxy and https_proxy defined in ENV' do
        it 'should return https proxy for https urls ' do
          stub_const('ENV', {'http_proxy' => 'http://httpproxy:3128', 'https_proxy' => 'http://httpsproxy:3129'})
          proxy_address, proxy_port = subject.http_proxy(URI('https://host/path'))
          expect(proxy_address).to eq('httpsproxy')
          expect(proxy_port).to be(3129)
        end
        it 'should return http proxy for for http urls ' do
          stub_const('ENV', {'http_proxy' => 'http://httpproxy:3128', 'https_proxy' => 'http://httpsproxy:3129'})
          proxy_address, proxy_port = subject.http_proxy(URI('http://host/path'))
          expect(proxy_address).to eq('httpproxy')
          expect(proxy_port).to be(3128)
        end
      end
    end

  end


end
