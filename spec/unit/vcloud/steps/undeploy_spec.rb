require "spec_helper"

module VCloudCloud
  module Steps
    describe Undeploy do
      it "Undeploy a vm" do
        client = double("vcloud client")
        vm = double("vm entity")
        vm.stub("[]").with("deployed") { 'true' }
        client.stub(:reload) { vm }
        client.stub(:logger) { Bosh::Clouds::Config.logger }
        undeploy_link = "link"
        vm.should_receive(:undeploy_link) { undeploy_link }
        client.should_receive(:invoke_and_wait).with(
          :post, undeploy_link, anything)

        Transaction.perform("undeploy", client) do |s|
          s.state[:vm] = vm
          s.next described_class, :vm
        end
      end
    end
  end
end
