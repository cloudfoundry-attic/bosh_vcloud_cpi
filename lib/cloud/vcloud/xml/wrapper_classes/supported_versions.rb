module VCloudSdk
  module Xml

    class SupportedVersions < Wrapper
      def login_url
        ns = 'http://www.vmware.com/vcloud/versions'
        get_nodes('VersionInfo', nil, false, ns).each do |node|
          if node.get_nodes('Version', nil, false, ns).first.content == VCloudClient::VCLOUD_VERSION_NUMBER
            return node.get_nodes('LoginUrl', nil, false, ns).first
          end
        end
      end
    end

  end
end
