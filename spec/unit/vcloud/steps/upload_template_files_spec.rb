require 'spec_helper'

module VCloudCloud
  module Steps
    describe UploadTemplateFiles do
      it "should upload template files" do
        client = double("vcloud client")
        client.stub(:logger) { Bosh::Clouds::Config.logger }
        client.stub(:reload) { |obj| obj }
        template = double("vapp_template")
        stemcell_dir = "/tmp"
        stemcell_ovf = "demo.ovf"

        ovf_file = double("ovf")
        vmdk_file = double("vmdk")
        ovf_upload_link = "ovf_upload_link"
        vmdk_upload_link = "vmdk_upload_link"
        vmdk_file_size = 10
        ovf_file.stub(:name) { stemcell_ovf }
        ovf_file.stub_chain("upload_link.href") { ovf_upload_link }
        ovf_file.stub(:read) { "file_content" }
        vmdk_file.stub(:name) { "demo.vmdk" }
        vmdk_file.stub_chain("upload_link.href") { vmdk_upload_link }
        vmdk_file.stub(:size) { vmdk_file_size }
        vmdk_file.stub(:path) { File.join(stemcell_dir, "demo.vmdk")}
        template.should_receive(:files).twice { [ ovf_file, vmdk_file ] }
        template.should_receive(:files).twice { [] }
        template.should_receive(:incomplete_files) { [ ovf_file, vmdk_file ] }
        File.should_receive(:new) { ovf_file }
        File.should_receive(:new) { vmdk_file }
        client.should_receive(:invoke).with(
          :put, ovf_upload_link, anything)
        client.should_receive(:upload_stream).with(
          vmdk_upload_link,vmdk_file_size, anything)
        client.stub(:wait_entity)

        Transaction.perform("upload_template_files", client) do |s|
          s.state[:stemcell_dir] = stemcell_dir
          s.state[:stemcell_ovf] = stemcell_ovf
          s.state[:vapp_template] = template
          s.next described_class
        end
      end
    end
  end
end
