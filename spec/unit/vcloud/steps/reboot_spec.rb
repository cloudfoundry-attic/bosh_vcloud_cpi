require 'spec_helper'
require_relative './shared_context'

module VCloudCloud
  module Steps
    describe Reboot do
      include_context "base"

      it "evoke reboot" do
        client.stub(:reload) { vm }
        client.stub(:logger) { Bosh::Clouds::Config.logger }
        reboot_link = "link"
        vm.should_receive(:reboot_link) { reboot_link }
        client.should_receive(:invoke_and_wait).with(:post, reboot_link)

        Transaction.perform("reboot", client) do |s|
          s.state[:vm] = vm
          s.next described_class, :vm
        end
      end
    end
  end
end
