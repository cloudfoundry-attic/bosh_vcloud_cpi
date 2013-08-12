shared_context "base" do
  let(:client) do
    client = double("vcloud client")
    client.stub(:logger) { Bosh::Clouds::Config.logger }
    client.stub(:reload) { |obj| obj }
    client
  end

  let(:vm) do
    vm = double("vm entity")
    vm.stub(:name) { "vm_name" }
    vm.stub(:urn) { "vm_urn" }
    vm
  end
end
