#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path(File.dirname(__FILE__) + '/../spec_helper.rb')

describe 'MessageDispatcher' do

  describe ".dispatch" do
    before do
      message_model(:dispatch_at => Time.now, :workflow_state => 'staged', :to => 'somebody', :updated_at => Time.now.utc - 11.minutes, :user => user, :path_type => 'email')
    end

    it "should reschedule on Mailer delivery error" do
      expect { MessageDispatcher.dispatch(@message) }.to change(Delayed::Job, :count).by(1)
      job = Delayed::Job.last(:order => :id)
      Mailer.expects(:deliver_message).raises(Timeout::Error)
      Delayed::Worker.new.perform(job)
      @message.reload.dispatch_at.should > Time.now.utc + 4.minutes
      job.reload.attempts.should == 1
      job.run_at.should == @message.dispatch_at
    end

    it "should not reschedule on cancelled Message" do
      expect { MessageDispatcher.dispatch(@message) }.to change(Delayed::Job, :count).by(1)
      @message.cancel
      job = Delayed::Job.last(:order => :id)
      Delayed::Worker.new.perform(job)
      @message.reload.state.should == :cancelled
      expect { job.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe ".batch_dispatch" do
    before do
      @messages = (0...3).map { message_model(:dispatch_at => Time.now, :workflow_state => 'staged', :to => 'somebody', :updated_at => Time.now.utc - 11.minutes, :user => user, :path_type => 'email') }
    end

    it "should reschedule on Mailer delivery error, but not on cancelled Message" do
      expect { MessageDispatcher.batch_dispatch(@messages) }.to change(Delayed::Job, :count).by(1)
      job = Delayed::Job.last(:order => :id)
      @messages[0].cancel

      Mailer.expects(:deliver_message).twice.raises(Timeout::Error).then.returns(true)

      expect { Delayed::Worker.new.perform(job) }.to change(Delayed::Job, :count).by(0) # one added, one finished
      @messages.each(&:reload)
      @messages.map(&:state).should == [:cancelled, :staged, :sent]
      @messages[1].dispatch_at.should > Time.now.utc + 4.minutes
      # the original job is complete, but the individual message gets re-scheduled in its own job
      expect { job.reload }.to raise_error(ActiveRecord::RecordNotFound)

      job = Delayed::Job.last(:order => :id)
      job.tag.should == 'Message#deliver'
      job.payload_object.object.should == @messages[1]
      job.run_at.should == @messages[1].dispatch_at
    end
  end
end
