require 'spec_helper'

module VCloudSdk
  module Xml
    describe Task do
      before(:each) do
        @task_xml = ::File.open("assets/instantiated_vapp_power_task_running.xml").read
        @task = WrapperFactory.wrap_document @task_xml
      end
      

      
      it "successfully creates a task object" do
        
        @task.should be_an_instance_of Task
      end
      
      it "has a start_time property" do
        @task.should respond_to(:start_time)
      end
      
      it "returns a Time object" do
        @task.start_time.should be_an_instance_of Time
      end
            
      
    end
  
  end
end