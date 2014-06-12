module VCloudCloud
  module Steps
    class EditVM < Step
      #Some vm attributes cannot be updated through reconfig link and instead we need to use edit link to update vm.
      # For now just storage profile is expected to be edited. But this editable parameter list is expected to evolve
      # as needed
      def perform(storage_profile,  &block)
        vm = state[:vm] = client.reload state[:vm]
        vm.storage_profile = storage_profile unless storage_profile.nil?
        client.invoke_and_wait :put, vm.edit_link,
                               :payload => vm,
                               :headers => { :content_type => VCloudSdk::Xml::MEDIA_TYPE[:VM] }

        state[:vm] = client.reload vm

      end
    end
  end
end
