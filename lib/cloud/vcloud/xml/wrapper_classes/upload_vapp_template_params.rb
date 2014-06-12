module VCloudSdk
  module Xml

    class UploadVAppTemplateParams < Wrapper
      def name=(name)
        @root["name"] = name
      end
      def storage_profile=(storage_profile)
        return unless storage_profile

        raise "vapp template upload storage profile already set." if @storage_profile
        @storage_profile = true
        node = create_child("VdcStorageProfile",
                            namespace.prefix,
                            namespace.href)
        node["type"] = storage_profile.type
        node["name"] = storage_profile.name
        node["href"] = storage_profile.href
        description.node.after(node) if description
      end

      private
      def description
        nodes = get_nodes("Description")
        return nodes.first if nodes
        return nil
      end
    end



  end
end
