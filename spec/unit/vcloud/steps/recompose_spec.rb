require "spec_helper"

module VCloudCloud
  module Steps
    describe Recompose do
      let(:client) do
        client = double("vcloud client")
        client.stub(:logger) { Bosh::Clouds::Config.logger }
        client.stub(:reload) { |arg| arg}
        client.should_receive(:invoke_and_wait).with(
          :post, recompose_link, anything
        )
        client
      end

      let(:recompose_link) { "recompose_link" }

      let(:vm) do
        vm = double("vm")
        vm.stub(:href) { "href" }
        vm
      end

      let(:vapp) do
        vapp = double("vapp")
        vapp.stub(:name) { vapp_name }
        vapp.should_receive(:recompose_vapp_link) { recompose_link }
        vapp
      end
      let(:vapp_name) { "vapp_name" }

      describe ".perform" do
        it "perform recompose" do
          state = {
            :vm => vm
          }
          described_class.new(state, client).perform(vapp)
        end
      end
    end
  end
end
