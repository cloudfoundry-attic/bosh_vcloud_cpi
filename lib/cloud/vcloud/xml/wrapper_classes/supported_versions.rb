module VCloudSdk
  module Xml

    class SupportedVersions < Wrapper
      def login_url
        get_nodes('LoginUrl', nil, false, 'http://www.vmware.com/vcloud/versions').first
      end
    end

  end
end
