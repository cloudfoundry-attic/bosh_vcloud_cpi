require "common/common"

require "digest/sha1"
require "fileutils"
require "logger"
require "securerandom"
require "yajl"
require "thread"

require_relative 'errors'
require_relative 'const'
require_relative 'util'
require_relative 'vcd_client'
require_relative 'steps'

module VCloudCloud

  class Cloud

    private
    
    def client
      @client_lock.synchronize do
        @client = VCloudClient.new(@vcd, @logger) if @client.nil?
      end
      @client
    end
    
    def steps(name, options = {}, &block)
      Transaction.perform name, client(), options, &block
    end
    
    public
    
    def initialize(options)
      @logger = Bosh::Clouds::Config.logger
      #VCloudSdk::Config.configure({ "logger" => @logger })
      @logger.debug("Input cloud options: #{options.inspect}")

      @agent_properties = options["agent"]
      vcds = options["vcds"]
      raise ArgumentError, "Invalid number of VCDs" unless vcds.size == 1
      @vcd = vcds[0]

      finalize_options
      
      @control = @vcd["control"]
      @retries = @control["retries"]
      @logger.info("VCD cloud options: #{options.inspect}")

      @client_lock = Mutex.new

      #at_exit { destroy_client }
    end

    def create_stemcell(image, _)
      (steps "create_stemcell(#{image}, _)" do |s|
        s.next Steps::StemcellInfo, image
        s.next Steps::CreateTemplate
        s.next Steps::UploadTemplateFiles
        s.next Steps::WaitTasks, s.state[:vapp_template]
        s.next Steps::AddCatalogItem, :vapp, s.state[:vapp_template]
      end)[:catalog_item].urn
    end

    def delete_stemcell(catalog_vapp_id)
      steps "delete_stemcell(#{catalog_vapp_id})" do |s|
        catalog_vapp = client.resolve_entity catalog_vapp_id
        raise CloudError, "Catalog vApp #{id} not found" unless catalog_vapp
        vapp = client.resolve_link catalog_vapp.entity
        s.next Steps::WaitTasks, vapp, :accept_failures => true
        client.invoke :delete, vapp.remove_link
        client.invoke :delete, catalog_vapp.href
      end
    end

    def create_vm(agent_id, catalog_vapp_id, resource_pool, networks, disk_locality = nil, environment = nil)
      (steps "create_vm(#{agent_id}, ...)" do |s|
        # request name available for recomposing vApps
        requested_name = environment && environment['vapp']
        vapp_name = requested_name.nil? ? agent_id : "vapp-tmp-#{SecureRandom.uuid}"

        # disk_locality should be an array of disk ids
        disk_locality = independent_disks disk_locality
        
        # agent_id is used as vm name
        description = @vcd['entities']['description']
        
        # if requested_name is present, we need to recompose vApp
        container_vapp = nil
        unless requested_name.nil?
          begin
            container_vapp = client.vapp_by_name requested_name
          rescue CloudError # TODO unify exceptions
            # ignored, keep container_vapp nil
            vapp_name = agent_id
          end
        end

        s.next Steps::Instantiate, catalog_vapp_id, vapp_name, description, disk_locality
        s.next Steps::WaitTasks, s.state[:vapp]
        vapp = s.state[:vapp] = client.reload s.state[:vapp]
        vm = s.state[:vm] = vapp.vms[0]
        
        # perform recomposing
        if container_vapp
          s.next Steps::WaitTasks, container_vapp
          s.next Steps::Recompose, container_vapp
          vapp = s.state[:vapp] = client.reload vapp
          s.next Steps::WaitTasks, vapp
          s.next Steps::DeleteVApp, vapp, true
          vapp = s.state[:vapp] = container_vapp
        end
        
        # save original disk configuration
        vapp = s.state[:vapp] = client.reload vapp
        vm = s.state[:vm] = client.reload vm
        s.state[:disks] = Array.new(vm.hardware_section.hard_disks)
        
        # reconfigure
        s.next Steps::AddNetworks, network_names(networks)
        s.next Steps::ReconfigureVM, agent_id, description, resource_pool, networks
        s.next Steps::DeleteUnusedNetworks, network_names(networks)
        
        # save env and generate env ISO image
        s.next Steps::SaveAgentEnv, @vcd['entities']['vm_metadata_key'], networks, environment
        
        vm = s.state[:vm] = client.reload vm
        # eject and delete old env ISO
        s.next Steps::EjectCatalogMedia, vm.name
        s.next Steps::DeleteCatalogMedia, vm.name
        
        # attach new env ISO
        storage_profiles = client.vdc.storage_profiles || []
        media_storage_profile = storage_profiles.find { |sp| sp['name'] == @vcd['entities']['media_storage_profile'] }
        s.next Steps::UploadCatalogMedia, vm.name, s.state[:iso], 'iso', media_storage_profile
        s.next Steps::AddCatalogItem, :media, s.state[:media]
        s.next Steps::InsertCatalogMedia, vm.name
        
        # power on
        s.next Steps::PowerOnVM
      end)[:vm].urn
    end
    
    def reboot_vm(vm_id)
      steps "reboot_vm(#{vm_id})" do |s|
        vm = s.state[:vm] = client.resolve_link client.resolve_entity(vm_id)
        if vm['status'] == VCloudSdk::Xml::RESOURCE_ENTITY_STATUS[:SUSPENDED].to_s
          s.next Steps::DiscardSuspendedState
          vm = s.state[:vm] = client.reload vm
          s.next WaitTasks vm
          s.next Steps::PowerOnVM
        elsif vm['status'] == VCloudSdk::Xml::RESOURCE_ENTITY_STATUS[:POWERED_OFF].to_s
          s.next Steps::PowerOnVM
        else
          s.next Steps::RebootVM
        end
      end
    end

    def has_vm?(vm_cid)
      client.resolve_entity vm_cid
      true
    rescue RestClient::Exception  # TODO unify exceptions
      false
    end

    def delete_vm(vapp_id)
      @client = client

      with_thread_name("delete_vm(#{vapp_id}, ...)") do
        Util.retry_operation("delete_vm(#{vapp_id}, ...)", @retries["cpi"],
            @control["backoff"]) do
          @logger.info("Deleting vApp: #{vapp_id}")
          vapp = @client.get_vapp(vapp_id)
          vm = get_vm(vapp)
          vm_name = vm.name

          begin
            @client.power_off_vapp(vapp)
          rescue VCloudSdk::VappSuspendedError => e
            @client.discard_suspended_state_vapp(vapp)
            @client.power_off_vapp(vapp)
          end
          del_vapp = @vcd["debug"]["delete_vapp"]
          @client.delete_vapp(vapp) if del_vapp
          @logger.info("Deleting ISO #{vm_name}")
          @client.delete_catalog_media(vm_name) if del_vapp
          @logger.info("Deleted vApp: #{vapp_id}")
        end
      end
    rescue VCloudSdk::CloudError => e
      log_exception("delete vApp #{vapp_id}", e)
      raise e
    end

    def configure_networks(vapp_id, networks)
      @client = client

      with_thread_name("configure_networks(#{vapp_id}, ...)") do
        Util.retry_operation("configure_networks(#{vapp_id}, ...)",
            @retries["cpi"], @control["backoff"]) do
          @logger.info("Reconfiguring vApp networks: #{vapp_id}")
          vapp, vm = get_vapp_vm_by_vapp_id(vapp_id)
          @logger.debug("Powering off #{vapp.name}.")
          begin
            @client.power_off_vapp(vapp)
          rescue VCloudSdk::VappSuspendedError => e
            @client.discard_suspended_state_vapp(vapp)
            @client.power_off_vapp(vapp)
          end

          add_vapp_networks(vapp, networks)
          @client.reconfigure_vm(vm) do |v|
            v.delete_nic(*vm.hardware_section.nics)
            add_vm_nics(v, networks)
          end
          delete_vapp_networks(vapp, networks)

          vapp, vm = get_vapp_vm_by_vapp_id(vapp_id)
          env = get_current_agent_env(vm)
          env["networks"] = generate_network_env(vm.hardware_section.nics,
            networks)
          @logger.debug("Updating agent env to: #{env.inspect}")
          set_agent_env(vm, env)

          @logger.debug("Powering #{vapp.name} back on.")
          @client.power_on_vapp(vapp)
          @logger.info("Configured vApp networks: #{vapp}")
        end
      end
    rescue VCloudSdk::CloudError => e
      log_exception("configure vApp networks: #{vapp}", e)
      raise e
    end

    def attach_disk(vapp_id, disk_id)
      @client = client

      with_thread_name("attach_disk(#{vapp_id} #{disk_id})") do
        Util.retry_operation("attach_disk(#{vapp_id}, #{disk_id})",
            @retries["cpi"], @control["backoff"]) do
          @logger.info("Attaching disk: #{disk_id} on vm: #{vapp_id}")

          vapp, vm = get_vapp_vm_by_vapp_id(vapp_id)
          # vm.hardware_section will change, save current state of disks
          disks_previous = Array.new(vm.hardware_section.hard_disks)

          disk = @client.get_disk(disk_id)
          @client.attach_disk(disk, vm)

          vapp, vm = get_vapp_vm_by_vapp_id(vapp_id)
          persistent_disk = get_newly_added_disk(vm, disks_previous)

          env = get_current_agent_env(vm)
          env["disks"]["persistent"][disk_id] = persistent_disk.disk_id
          @logger.info("Updating agent env to: #{env.inspect}")
          set_agent_env(vm, env)

          @logger.info("Attached disk:#{disk_id} to VM:#{vapp_id}")
        end
      end
    rescue VCloudSdk::CloudError => e
      log_exception("attach disk", e)
      raise e
    end

    def detach_disk(vapp_id, disk_id)
      @client = client

      with_thread_name("detach_disk(#{vapp_id} #{disk_id})") do
        Util.retry_operation("detach_disk(#{vapp_id}, #{disk_id})",
            @retries["cpi"], @control["backoff"]) do
          @logger.info("Detaching disk: #{disk_id} from vm: #{vapp_id}")

          vapp, vm = get_vapp_vm_by_vapp_id(vapp_id)

          disk = @client.get_disk(disk_id)
          begin
            @client.detach_disk(disk, vm)
          rescue VCloudSdk::VmSuspendedError => e
            @client.discard_suspended_state_vapp(vapp)
            @client.detach_disk(disk, vm)
          end

          env = get_current_agent_env(vm)
          env["disks"]["persistent"].delete(disk_id)
          @logger.info("Updating agent env to: #{env.inspect}")
          set_agent_env(vm, env)

          @logger.info("Detached disk: #{disk_id} on vm: #{vapp_id}")
        end
      end
    rescue VCloudSdk::CloudError => e
      log_exception("detach disk", e)
      raise e
    end

    def create_disk(size_mb, vm_locality = nil)
      @client = client

      with_thread_name("create_disk(#{size_mb}, vm_locality)") do
        Util.retry_operation("create_disk(#{size_mb}, vm_locality)",
            @retries["cpi"], @control["backoff"]) do
          @logger.info("Create disk: #{size_mb}, #{vm_locality}")
          disk_name = "#{generate_unique_name}"
          disk = nil
          if vm_locality.nil?
            @logger.info("Creating disk: #{disk_name} #{size_mb}")
            disk = @client.create_disk(disk_name, size_mb)
          else
            # vm_locality => vapp_id
            vapp, vm = get_vapp_vm_by_vapp_id(vm_locality)
            @logger.info("Creating disk: #{disk_name} #{size_mb} #{vm.name}")
            disk = @client.create_disk(disk_name, size_mb, vm)
          end
          @logger.info("Created disk: #{disk_name} #{disk.urn} #{size_mb} " +
            "#{vm_locality}")
          disk.urn
        end
      end
    rescue VCloudSdk::CloudError => e
      log_exception("create disk", e)
      raise e
    end

    def delete_disk(disk_id)
      @client = client

      with_thread_name("delete_disk(#{disk_id})") do
        Util.retry_operation("delete_disk(#{disk_id})", @retries["cpi"],
            @control["backoff"]) do
          @logger.info("Deleting disk: #{disk_id}")
          disk = @client.get_disk(disk_id)
          @client.delete_disk(disk)
          @logger.info("Deleted disk: #{disk_id}")
        end
      end
    rescue VCloudSdk::CloudError => e
      log_exception("delete disk", e)
      raise e
    end

    def get_disk_size_mb(disk_id)
      @client = client

      with_thread_name("get_disk_size(#{disk_id})") do
        Util.retry_operation("get_disk_size(#{disk_id})", @retries["cpi"],
            @control["backoff"]) do
          @logger.info("Getting disk size: #{disk_id}")
          disk = @client.get_disk(disk_id)
          @logger.info("Disk #{disk_id} size: #{disk.size_mb} MB")
          disk.size_mb
        end
      end
    rescue VCloudSdk::CloudError => e
      log_exception("get_disk_size", e)
      raise e
    end

    def validate_deployment(old_manifest, new_manifest)
      # There is TODO in vSphere CPI that questions the necessity of this method
      raise NotImplementedError, "validate_deployment"
    end

    private

    def finalize_options
      @vcd["control"] = {} unless @vcd["control"]
      @vcd["control"]["retries"] = {} unless @vcd["control"]["retries"]
      @vcd["control"]["retries"]["default"] ||= RETRIES_DEFAULT
      @vcd["control"]["retries"]["upload_vapp_files"] ||=
        RETRIES_UPLOAD_VAPP_FILES
      @vcd["control"]["retries"]["cpi"] ||= RETRIES_CPI
      @vcd["control"]["delay"] ||= DELAY
      @vcd["control"]["time_limit_sec"] = {} unless
        @vcd["control"]["time_limit_sec"]
      @vcd["control"]["time_limit_sec"]["default"] ||= TIMELIMIT_DEFAULT
      @vcd["control"]["time_limit_sec"]["delete_vapp_template"] ||=
        TIMELIMIT_DELETE_VAPP_TEMPLATE
      @vcd["control"]["time_limit_sec"]["delete_vapp"] ||= TIMELIMIT_DELETE_VAPP
      @vcd["control"]["time_limit_sec"]["delete_media"] ||=
        TIMELIMIT_DELETE_MEDIA
      @vcd["control"]["time_limit_sec"]["instantiate_vapp_template"] ||=
        TIMELIMIT_INSTANTIATE_VAPP_TEMPLATE
      @vcd["control"]["time_limit_sec"]["power_on"] ||= TIMELIMIT_POWER_ON
      @vcd["control"]["time_limit_sec"]["power_off"] ||= TIMELIMIT_POWER_OFF
      @vcd["control"]["time_limit_sec"]["undeploy"] ||= TIMELIMIT_UNDEPLOY
      @vcd["control"]["time_limit_sec"]["process_descriptor_vapp_template"] ||=
        TIMELIMIT_PROCESS_DESCRIPTOR_VAPP_TEMPLATE
      @vcd["control"]["time_limit_sec"]["http_request"] ||=
        TIMELIMIT_HTTP_REQUEST
      @vcd["control"]["backoff"] ||= BACKOFF
      @vcd["control"]["rest_throttle"] = {} unless
        @vcd["control"]["rest_throttle"]
      @vcd["control"]["rest_throttle"]["min"] ||= REST_THROTTLE_MIN
      @vcd["control"]["rest_throttle"]["max"] ||= REST_THROTTLE_MAX
      @vcd["debug"] = {} unless @vcd["debug"]
      @vcd["debug"]["delete_vapp"] = DEBUG_DELETE_VAPP unless
        @vcd["debug"]["delete_vapp"]
    end

    def create_client
      url = @vcd["url"]
      @logger.debug("Create session to VCD cloud: #{url}")

      @client = VCloudSdk::Client.new(url, @vcd["user"],
        @vcd["password"], @vcd["entities"], @vcd["control"])

      @logger.info("Created session to VCD cloud: #{url}")

      @client
    rescue VCloudSdk::ApiError => e
      log_exception(e, "Failed to connect and establish session.")
      raise e
    end

    def destroy_client
      url = @vcd["url"]
      @logger.debug("Destroy session to VCD cloud: #{url}")
      # TODO VCloudSdk::Client should permit logout.
      @logger.info("Destroyed session to VCD cloud: #{url}")
    end

    def generate_unique_name
      SecureRandom.uuid
    end

    def log_exception(op, e)
      @logger.error("Failed to #{op}.")
      @logger.error(e)
    end

    def generate_network_env(nics, networks)
      nic_net = {}
      nics.each do |nic|
        nic_net[nic.network] = nic
      end
      @logger.debug("nic_net #{nic_net.inspect}")

      network_env = {}
      networks.each do |network_name, network|
        network_entry = network.dup
        v_network_name = network["cloud_properties"]["name"]
        nic = nic_net[v_network_name]
        if nic.nil? then
          @logger.warn("Not generating network env for #{v_network_name}")
          next
        end
        network_entry["mac"] = nic.mac_address
        network_env[network_name] = network_entry
      end
      network_env
    end

    def generate_disk_env(system_disk, ephemeral_disk)
      {
        "system" => system_disk.disk_id,
        "ephemeral" => ephemeral_disk.disk_id,
        "persistent" => {}
      }
    end

    def generate_agent_env(name, vm, agent_id, networking_env, disk_env)
      vm_env = {
        "name" => name,
        "id" => vm.urn
      }

      env = {}
      env["vm"] = vm_env
      env["agent_id"] = agent_id
      env["networks"] = networking_env
      env["disks"] = disk_env
      env.merge!(@agent_properties)
    end

    def get_current_agent_env(vm)
      env = @client.get_metadata(vm, @vcd["entities"]["vm_metadata_key"])
      @logger.info("Current agent env: #{env.inspect}")
      Yajl::Parser.parse(env)
    end

    def genisoimage  # TODO: this should exist in bosh_common, eventually
      @genisoimage ||= Bosh::Common.which(%w{genisoimage mkisofs})
    end

    def set_agent_env(vm, env)
      env_json = Yajl::Encoder.encode(env)
      @logger.debug("env.iso content #{env_json}")

      begin
        # Clear existing ISO if one exists.
        @logger.info("Ejecting ISO #{vm.name}")
        @client.eject_catalog_media(vm, vm.name)
        @logger.info("Deleting ISO #{vm.name}")
        @client.delete_catalog_media(vm.name)
      rescue VCloudSdk::ObjectNotFoundError
        @logger.debug("No ISO to eject/delete before setting new agent env.")
        # Continue setting agent env...
      end

      # generate env iso, and insert into VM
      Dir.mktmpdir do |path|
        env_path = File.join(path, "env")
        iso_path = File.join(path, "env.iso")
        File.open(env_path, "w") { |f| f.write(env_json) }
        output = `#{genisoimage} -o #{iso_path} #{env_path} 2>&1`
        raise "#{$?.exitstatus} -#{output}" if $?.exitstatus != 0

        @client.set_metadata(vm, @vcd["entities"]["vm_metadata_key"], env_json)

        storage_profiles = @client.get_ovdc.storage_profiles || []
        media_storage_profile = storage_profiles.find { |sp| sp["name"] ==
          @vcd["entities"]["media_storage_profile"] }
        @logger.info("Uploading and inserting ISO #{iso_path} as #{vm.name} " +
          "to #{media_storage_profile.inspect}")
        @client.upload_catalog_media(vm.name, iso_path, media_storage_profile)
        @client.insert_catalog_media(vm, vm.name)
        @logger.info("Uploaded and inserted ISO #{iso_path} as #{vm.name}")
      end
    end

    def delete_vapp_networks(vapp, exclude_nets)
      exclude = exclude_nets.map { |k,v| v["cloud_properties"]["name"] }.uniq
      @client.delete_networks(vapp, exclude)
      @logger.debug("Deleted vApp #{vapp.name} networks excluding " +
        "#{exclude.inspect}.")
    end

    def add_vapp_networks(vapp, networks)
      @logger.debug("Networks to add: #{networks.inspect}")
      ovdc = @client.get_ovdc
      accessible_org_networks = ovdc.available_networks
      @logger.debug("Accessible Org nets: #{accessible_org_networks.inspect}")

      cloud_networks = networks.map { |k,v| v["cloud_properties"]["name"] }.uniq
      cloud_networks.each do |configured_network|
        @logger.debug("Adding configured network: #{configured_network}")
        org_net = accessible_org_networks.find {
          |n| n["name"] == configured_network }
        unless org_net
          raise VCloudSdk::CloudError, "Configured network: " +
            "#{configured_network}, is not accessible to VDC:#{ovdc.name}."
        end
        @logger.debug("Adding configured network: #{configured_network}, => " +
          "Org net:#{org_net.inspect} to vApp:#{vapp.name}.")
        @client.add_network(vapp, org_net)
        @logger.debug("Added vApp network: #{configured_network}.")
      end
      @logger.debug("Accessible configured networks added:#{networks.inspect}.")
    end

    def add_vm_nics(v, networks)
      networks.values.each_with_index do |network, nic_index|
        if nic_index + 1 >= VM_NIC_LIMIT then
          @logger.warn("Max number of NICs reached")
          break
        end
        configured_network = network["cloud_properties"]["name"]
        @logger.info("Adding NIC with IP address #{network["ip"]}.")
        v.add_nic(nic_index, configured_network,
          VCloudSdk::Xml::IP_ADDRESSING_MODE[:MANUAL], network["ip"])
        v.connect_nic(nic_index, configured_network,
          VCloudSdk::Xml::IP_ADDRESSING_MODE[:MANUAL], network["ip"])
      end
      @logger.info("NICs added to #{v.name} and connected to network:" +
                   " #{networks.inspect}")
    end

    def get_vm(vapp)
      vms = vapp.vms
      raise IndexError, "Invalid number of vApp VMs" unless vms.size == 1
      vms[0]
    end

    def get_vapp_vm_by_vapp_id(id)
      vapp = @client.get_vapp(id)
      [vapp, get_vm(vapp)]
    end

    def get_newly_added_disk(vm, disks_previous)
      disks_current = vm.hardware_section.hard_disks
      newly_added = disks_current - disks_previous

      if newly_added.size != 1
        @logger.debug("Previous disks in #{vapp_id}: #{disks_previous.inspect}")
        @logger.debug("Current disks in #{vapp_id}:  #{disks_current.inspect}")
        raise IndexError, "Expecting #{disks_previous.size + 1} disks, found " +
              "#{disks_current.size}"
      end

      @logger.info("Newly added disk: #{newly_added[0]}")
      newly_added[0]
    end

    def independent_disks(disk_locality)
      disk_locality ||= []
      @logger.info "Instantiate vApp accessible to disks: #{disk_locality.join(',')}"
      disk_locality.map do |disk_id|
        client.resolve_entity disk_id
      end
    end

    def network_names(networks)
      networks.map { |k,v| v['cloud_properties']['name'] }.uniq
    end
  end

end