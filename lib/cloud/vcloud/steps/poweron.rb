module VCloudCloud
  module Steps
    class PowerOn < Step
      def perform(ref, &block)
        entity = client.reload state[ref]
        if entity['status'] == VCloudSdk::Xml::RESOURCE_ENTITY_STATUS[:POWERED_ON].to_s
          @logger.debug "#{entity.name} already powered on"
          return
        end
        poweron_link = entity.power_on_link
        raise "#{entity.name} unable to power on" unless poweron_link
        state[:poweron_ref] = ref
        client.invoke_and_wait :post, poweron_link
        state[ref] = client.reload entity
      end

      def rollback
        ref = state[:poweron_ref]
        if ref
          begin
            entity = client.reload ref
            if entity['status'] == VCloudSdk::Xml::RESOURCE_ENTITY_STATUS[:POWERED_OFF].to_s
              @logger.debug "#{entity.name} already powered off"
              return
            end

            poweroff_link = entity.power_off_link
            client.invoke_and_wait :post, poweroff_link
          rescue => ex
            @logger.debug(ex) if @logger
          end
        end
      end
    end
  end
end
