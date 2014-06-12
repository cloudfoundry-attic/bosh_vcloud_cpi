require "spec_helper"
module VCloudCloud
  module Steps
    describe EditVM do
      let(:client) do
        client = double("vcloud client")
        client.stub(:logger) { Bosh::Clouds::Config.logger }
        client.stub(:reload) { |arg| arg}
        client.should_receive(:invoke_and_wait).with(
          :put, edit_link, anything)
        client
      end


      let(:edit_link) { "edit_link" }
      let(:vm) do
        vm = double("vm")
        vm.should_receive(:storage_profile=)
        vm.should_receive(:edit_link)  { edit_link}
        vm
      end

      let(:storage_profile) { {
          "name" => "small",
          "href" => "h"
      } }


      it "edit a vm" do
        Transaction.perform("reboot", client) do |s|
          s.state[:vm] = vm
          s.next described_class, storage_profile
        end
      end
    end
  end
end
