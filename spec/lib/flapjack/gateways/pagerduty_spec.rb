require 'spec_helper'

require 'flapjack/gateways/pagerduty'

describe Flapjack::Gateways::Pagerduty, :logger => true do

  let(:config) { {'queue'    => 'pagerduty_notifications'} }

  let(:now)   { Time.now }

  let(:redis) { double(Redis) }
  let(:lock)  { double(Monitor) }

  before(:each) do
    Flapjack.stub(:redis).and_return(redis)
  end

  context 'notifications' do

    let(:message) { {'notification_type'  => 'problem',
                     'contact_first_name' => 'John',
                     'contact_last_name' => 'Smith',
                     'address' => 'pdservicekey',
                     'state' => 'critical',
                     'state_duration' => 23,
                     'summary' => '',
                     'last_state' => 'OK',
                     'last_summary' => 'TEST',
                     'details' => 'Testing',
                     'time' => now.to_i,
                     'entity' => 'app-02',
                     'check' => 'ping'}
                  }

    # TODO use separate threads in the test instead?
    it "starts and is stopped by an exception" do
      Kernel.should_receive(:sleep).with(10)

      redis.should_receive(:rpop).with('pagerduty_notifications').and_return(message.to_json, nil)
      redis.should_receive(:quit)
      redis.should_receive(:brpop).with('pagerduty_notifications_actions').and_raise(Flapjack::PikeletStop)

      lock.should_receive(:synchronize).and_yield

      fpn = Flapjack::Gateways::Pagerduty::Notifier.new(:lock => lock,
        :config => config, :logger => @logger)
      fpn.should_receive(:handle_message).with(message)
      fpn.should_receive(:test_pagerduty_connection).twice.and_return(false, true)
      expect { fpn.start }.to raise_error(Flapjack::PikeletStop)
    end

    it "tests the pagerduty connection" do
      fpn = Flapjack::Gateways::Pagerduty::Notifier.new(:config => config, :logger => @logger)

      req = stub_request(:post, "https://events.pagerduty.com/generic/2010-04-15/create_event.json").
         with(:body => {'service_key'  => '11111111111111111111111111111111',
                        'incident_key' => 'Flapjack is running a NOOP',
                        'event_type'   => 'nop',
                        'description'  => 'I love APIs with noops.'}.to_json).
         to_return(:status => 200, :body => {'status' => 'success'}.to_json)

      fpn.send(:test_pagerduty_connection)
      req.should have_been_requested
    end

    it "handles notifications received via Redis" do
      fpn = Flapjack::Gateways::Pagerduty::Notifier.new(:config => config, :logger => @logger)

      req = stub_request(:post, "https://events.pagerduty.com/generic/2010-04-15/create_event.json").
         with(:body => {'service_key'  => 'pdservicekey',
                        'incident_key' => 'app-02:ping',
                        'event_type'   => 'trigger',
                        'description'  => 'Problem: "ping" on app-02 is Critical'}.to_json).
         to_return(:status => 200, :body => {'status' => 'success'}.to_json)

      fpn.send(:handle_message, message)
      req.should have_been_requested
    end

  end

  context 'acknowledgements' do

    let(:entity_check) { double(Flapjack::Data::Check) }

    let(:status_change) { {'id'        => 'ABCDEFG',
                           'name'      => 'John Smith',
                           'email'     => 'johns@example.com',
                           'html_url'  => 'http://flpjck.pagerduty.com/users/ABCDEFG'}
                        }

    # TODO use separate threads in the test instead?
    it "doesn't look for acknowledgements if this search is already running" do
      redis.should_receive(:del).with('sem_pagerduty_acks_running')

      redis.should_receive(:setnx).with('sem_pagerduty_acks_running', 'true').and_return(0)

      Kernel.should_receive(:sleep).with(10).and_raise(Flapjack::PikeletStop.new)

      lock.should_receive(:synchronize).and_yield

      fpa = Flapjack::Gateways::Pagerduty::AckFinder.new(:lock => lock,
        :config => config, :logger => @logger)
      expect { fpa.start }.to raise_error(Flapjack::PikeletStop)
    end

    # TODO use separate threads in the test instead?
    it "looks for and creates acknowledgements if the search is not already running" do
      redis.should_receive(:del).with('sem_pagerduty_acks_running').twice

      redis.should_receive(:setnx).with('sem_pagerduty_acks_running', 'true').and_return(1)
      redis.should_receive(:expire).with('sem_pagerduty_acks_running', 300)

      contact = double(Flapjack::Data::Contact)
      contact.should_receive(:pagerduty_credentials).and_return({
        'service_key' => '12345678',
        'subdomain"'  => 'flpjck',
        'username'    => 'flapjack',
        'password'    => 'password123'
      })

      contacts_all = double(:contacts, :all => [contact])
      entity_check.should_receive(:contacts).and_return(contacts_all)
      entity_check.should_receive(:entity_name).twice.and_return('foo-app-01.bar.net')
      entity_check.should_receive(:name).twice.and_return('PING')
      entity_check.should_receive(:in_unscheduled_maintenance?).and_return(false)

      failing_checks = double('failing_checks', :all => [entity_check])
      Flapjack::Data::Check.should_receive(:intersect).with(:state =>
        ['critical', 'warning', 'unknown']).and_return(failing_checks)

      Flapjack::Data::Event.should_receive(:create_acknowledgement).with('events',
        'foo-app-01.bar.net', 'PING',
        :summary => 'Acknowledged on PagerDuty by John Smith',
        :duration => 14400)

      Kernel.should_receive(:sleep).with(10).and_raise(Flapjack::PikeletStop.new)

      response = {:pg_acknowledged_by => status_change}

      lock.should_receive(:synchronize).and_yield

      fpa = Flapjack::Gateways::Pagerduty::AckFinder.new(:lock => lock,
        :config => config, :logger => @logger)
      fpa.should_receive(:pagerduty_acknowledged?).and_return(response)
      expect { fpa.start }.to raise_error(Flapjack::PikeletStop)
    end

    # testing separately and stubbing above
    it "looks for acknowledgements via the PagerDuty API" do
      check = 'PING'
      since = (now.utc - (60*60*24*7)).iso8601 # the last week
      unt   = (now.utc + (60*60*24)).iso8601   # 1 day in the future

      response = {"incidents" =>
        [{"incident_number" => 12,
          "status" => "acknowledged",
          "last_status_change_by" => status_change}],
        "limit"=>100,
        "offset"=>0,
        "total"=>1}

      req = stub_request(:get, "https://flapjack:password123@flpjck.pagerduty.com/api/v1/incidents").
        with(:query => {:fields => 'incident_number,status,last_status_change_by',
                        :incident_key => check, :since => since, :until => unt,
                        :status => 'acknowledged'}).
        to_return(:status => 200, :body => response.to_json, :headers => {})

      redis.should_receive(:del).with('sem_pagerduty_acks_running')

      fpa = Flapjack::Gateways::Pagerduty::AckFinder.new(:config => config, :logger => @logger)

      result = fpa.send(:pagerduty_acknowledged?, 'subdomain' => 'flpjck',
        'username' => 'flapjack', 'password' => 'password123', 'check' => check)

      result.should be_a(Hash)
      result.should have_key(:pg_acknowledged_by)
      result[:pg_acknowledged_by].should be_a(Hash)
      result[:pg_acknowledged_by].should have_key('id')
      result[:pg_acknowledged_by]['id'].should == 'ABCDEFG'

      req.should have_been_requested
    end

  end

end
