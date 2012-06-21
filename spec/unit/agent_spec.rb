# Copyright (c) 2009-2011 VMware, Inc.
require File.join(File.dirname(__FILE__), 'spec_helper')

require 'dea/agent'

describe 'DEA Agent' do
  UNIT_TESTS_DIR = "/tmp/dea_agent_unit_tests_#{Process.pid}_#{Time.now.to_i}"

  before :each do
    FileUtils.mkdir(UNIT_TESTS_DIR)
    File.directory?(UNIT_TESTS_DIR).should be_true
  end

  after :each do
    FileUtils.rm_rf(UNIT_TESTS_DIR)
    File.directory?(UNIT_TESTS_DIR).should be_false
  end

  describe '.ensure_writable' do
    it "should raise exceptions if directory isn't writable" do
      dir = File.join(UNIT_TESTS_DIR, 'not_writable')
      FileUtils.mkdir(dir)
      File.directory?(dir).should be_true
      FileUtils.chmod(0500, dir)
      lambda { DEA::Agent.ensure_writable(dir) }.should raise_error
    end
  end

  describe '#dump_apps_dir' do
    it "should log directory summary and details" do
      agent = make_test_agent
      apps_dir = create_apps_dir(UNIT_TESTS_DIR)
      File.directory?(apps_dir).should be_true

      du_pid = agent.dump_apps_dir
      begin
        Process.waitpid(du_pid)
      rescue Errno::ECHILD
        # The agent detaches du_pid, consequently, the ruby thread that was set up
        # to reap the child status may have already done so.
      end

      logs = Dir.glob(File.join(UNIT_TESTS_DIR, 'apps.du.*'))
      logs.length.should == 2
    end
  end

  describe '#delete_untracked_instance_dirs' do
    it 'should not remove instance dirs for tracked apps' do
      agent = make_test_agent
      apps_dir = create_apps_dir(UNIT_TESTS_DIR)
      File.directory?(apps_dir).should be_true

      inst_dir = File.join(apps_dir, 'test_instance_dir')
      FileUtils.mkdir(inst_dir)
      File.directory?(inst_dir).should be_true

      agent.instance_variable_set(:@droplets, {1 => {0 => {:dir => inst_dir}}})
      agent.delete_untracked_instance_dirs

      File.directory?(inst_dir).should be_true
    end

    it 'should remove instance dirs for untracked apps' do
      agent = make_test_agent
      apps_dir = create_apps_dir(UNIT_TESTS_DIR)
      File.directory?(apps_dir).should be_true

      inst_dir = File.join(apps_dir, 'test_instance_dir')
      FileUtils.mkdir(inst_dir)
      File.directory?(inst_dir).should be_true

      agent.instance_variable_set(:@droplets, {})
      agent.delete_untracked_instance_dirs

      File.directory?(inst_dir).should be_false
    end
  end

  describe '#crashes_reaper' do
    it 'should remove instance dirs for crashed apps' do
      agent = make_test_agent
      inst_dir = create_crashed_app(UNIT_TESTS_DIR)
      set_crashed_app_state(agent, inst_dir)

      EM.run do
        agent.crashes_reaper
        EM.stop
      end

      File.directory?(inst_dir).should be_false
    end
  end

  describe '#stage_app_dir' do
    before :each do
      @tmp_dir = Dir.mktmpdir
      @bad_tgz = File.join(@tmp_dir, 'test.tgz')
      File.open(@bad_tgz, 'w+') {|f| f.write("Hello!") }
    end

    after :each do
      FileUtils.rm_rf(@tmp_dir)
    end

    it 'should return false if creating the instance dir fails' do
      agent = make_test_agent
      # Foo doesn't exist, so creating foo/bar should fail
      inst_dir = File.join(@tmp_dir, 'foo', 'bar')
      agent.stage_app_dir(nil, nil, nil, @bad_tgz, inst_dir, nil).should be_false
    end

    it 'should return false if creating the instance dir fails' do
      agent = make_test_agent
      inst_dir = File.join(@tmp_dir, 'foo')
      # @bad_tgz isn't a valid tar file, so extraction should fail
      agent.stage_app_dir(nil, nil, nil, @bad_tgz, inst_dir, nil).should be_false
    end
  end

  describe '#cleanup_droplet' do
    it 'should rechown instance dirs for crashed apps' do
      agent = make_test_agent
      inst_dir = create_crashed_app(UNIT_TESTS_DIR)
      set_crashed_app_state(agent, inst_dir)

      # Use Rspec "EM.system.should_recieve ... "cmd here"
      #EM.should_receive(:system).once.with("chown -R #{Process.euid}:#{Process.egid} #{inst_dir}")
      EM.should_receive(:system).once
      agent.cleanup_droplet(agent.instance_variable_get(:@droplets)[0][0])

      # Is this test blocking? Does it matter?
      File.owned?(inst_dir).should be_true
    end
  end

  describe '#update_droplet_fs_usage' do
    it 'should return the disk usage percentage as an integer' do
      agent = make_test_agent
      agent.update_droplet_fs_usage(:blocking => true)
      agent.instance_variable_get(:@droplet_fs_percent_used).should be_kind_of(Integer)
    end

    it 'should raise exception if droplet_dir does not exists' do
      agent = make_test_agent
      agent.instance_variable_set(:@droplet_dir, "/dea_dummy_dir")
      expect {
        agent.update_droplet_fs_usage(:blocking => true)
      }.to raise_exception
    end
  end

  describe '#bind_local_runtime' do
    it 'should replace VCAP_LOCAL_RUNTIME in startup' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtimes, {'ruby18'=>{'executable'=>'/usr/bin/ruby',
        'expanded_executable'=>'/usr/bin/ruby', 'enabled'=>true}})
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      apps_dir = create_apps_dir(UNIT_TESTS_DIR)
      File.directory?(apps_dir).should be_true
      inst_dir = File.join(apps_dir, 'test_instance_dir')
      FileUtils.mkdir(inst_dir)
      File.directory?(inst_dir).should be_true
      startup = File.join(inst_dir, 'startup')
      File.open(startup, 'w') { |f| f.write("%VCAP_LOCAL_RUNTIME% foo.rb") }
      agent.bind_local_runtime(inst_dir, {'name'=>'ruby18'})
      startup_contents = File.read(startup)
      startup_contents.should == "/usr/bin/ruby foo.rb"
    end

    it 'should do nothing if startup file does not exist' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtimes, {'ruby18'=>{'executable'=>'/usr/bin/ruby', 'enabled'=>true}})
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      apps_dir = create_apps_dir(UNIT_TESTS_DIR)
      File.directory?(apps_dir).should be_true
      inst_dir = File.join(apps_dir, 'test_instance_dir')
      FileUtils.mkdir(inst_dir)
      File.directory?(inst_dir).should be_true
      agent.bind_local_runtime(inst_dir, {'name'=>'ruby18'})
    end

    it 'should do nothing if instance dir does not exist' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtimes, {'ruby18'=>{'executable'=>'/usr/bin/ruby', 'enabled'=>true}})
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.bind_local_runtime('fake_dir', {'name'=>'ruby18'})
    end
  end

  describe '#initialize_runtime' do
    it 'disables runtime if executable not found' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.initialize_runtime({'name'=>'ruby18','executable'=>'/does/not/exist'})
      agent.instance_variable_get(:@runtimes).should== {'ruby18'=>{'name'=>'ruby18',
                                                                   'executable'=>'/does/not/exist',
                                                                    'enabled'=>false}}
    end
    it 'disables runtime if unable to run version check' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>'-foo'})
      agent.instance_variable_get(:@runtimes)['ruby18']['enabled'].should== false
    end
    it 'disables runtime if version_output is missing' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'"})
      agent.instance_variable_get(:@runtimes)['ruby18']['enabled'].should== false
    end

    it 'disables runtime if version mismatch' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.9.2'})
      agent.instance_variable_get(:@runtimes)['ruby18']['enabled'].should== false
    end

    it 'disables runtime if additional checks fail' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'additional_checks'=>'-foo'})
      agent.instance_variable_get(:@runtimes)['ruby18']['enabled'].should== false
    end

    it 'enables runtime if all checks pass' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7'})
      agent.instance_variable_get(:@runtimes)['ruby18']['enabled'].should== true
    end

    it 'runs version check again if executable has changed' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes,{'ruby18'=>{'name'=>'ruby18',
                                    'version_flag'=>"-e 'puts RUBY_VERSION'", 'executable'=> '/not/ruby/path',
                                    'version_output'=>'1.8.7', 'enabled'=> false}})
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7'})
      agent.instance_variable_get(:@runtimes)['ruby18'].should == {'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'enabled' => true,
                                'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8'}
    end

   it 'runs version check again if version_output has changed' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes,{'ruby18'=>{'name'=>'ruby18',
                                    'version_flag'=>"-e 'puts RUBY_VERSION'", 'executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'version_output'=>'1.8.2', 'enabled'=> false}})
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7'})
      agent.instance_variable_get(:@runtimes)['ruby18'].should == {'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'enabled' => true,
                                'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8'}
    end

    it 'runs version check again if version_flag has changed' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes,{'ruby18'=>{'name'=>'ruby18',
                                    'version_flag'=>"-e 'puts THE_RUBY_VERSION'", 'executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'version_output'=>'1.8.7', 'enabled'=> false}})
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7'})
      agent.instance_variable_get(:@runtimes)['ruby18'].should == {'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'enabled' => true,
                                'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8'}
    end

    it 'runs version check again if additional_checks has changed' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes,{'ruby18'=>{'name'=>'ruby18',
                                    'version_flag'=>"-e 'puts RUBY_VERSION'", 'executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'version_output'=>'1.8.7', 'additional_checks'=> 'something else','enabled'=> false}})
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7'})
      agent.instance_variable_get(:@runtimes)['ruby18'].should == {'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'enabled' => true,
                                'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8'}
    end

    it "adds new data to cached map when not re-running version check" do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes,{'ruby18'=>{'name'=>'ruby18',
                                    'version_flag'=>"-e 'puts RUBY_VERSION'", 'executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'version_output'=>'1.8.7', 'enabled'=> true}})
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'foo'=> 'bar'})
      agent.instance_variable_get(:@runtimes)['ruby18'].should == {'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'enabled' => true,
                                'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8', 'foo'=> 'bar'}
    end

   it "updates existing data in cached map when not re-running version check" do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes,{'ruby18'=>{'name'=>'ruby18',
                                    'version_flag'=>"-e 'puts RUBY_VERSION'", 'executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'version_output'=>'1.8.7', 'enabled'=> true, 'foo'=>'bar'}})
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'foo'=> 'baz'})
      agent.instance_variable_get(:@runtimes)['ruby18'].should == {'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'enabled' => true,
                                'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8', 'foo'=> 'baz'}
    end

    it "removes property from cached map when not re-running version check" do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes,{'ruby18'=>{'name'=>'ruby18',
                                    'version_flag'=>"-e 'puts RUBY_VERSION'", 'executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                    'version_output'=>'1.8.7', 'enabled'=> true, 'foo'=>'bar'}})
      agent.initialize_runtime({'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7'})
      agent.instance_variable_get(:@runtimes)['ruby18'].should == {'name'=>'ruby18','executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8',
                                'version_flag'=>"-e 'puts RUBY_VERSION'", 'version_output'=>'1.8.7', 'enabled' => true,
                                'expanded_executable'=> ENV["VCAP_TEST_DEA_RUBY18"] || '/usr/bin/ruby1.8'}
    end

  end

  describe '#runtime_supported?' do
    it 'returns false if runtime name not in config' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.runtime_supported?({'name'=>'java'}).should == false
    end

     it 'returns false if runtime not enabled' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes, {'ruby18'=>{'enabled'=> false}})
      agent.runtime_supported?({'name'=>'ruby18'}).should == false
    end

    it 'returns true if runtime is enabled' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtime_names, ['ruby18'])
      agent.instance_variable_set(:@runtimes, {'ruby18'=>{'enabled'=> true}})
      agent.runtime_supported?({'name'=>'ruby18'}).should == true
    end
  end

  describe '#runtime_env' do
    it 'returns runtime env variables' do
      agent = make_test_agent
      agent.instance_variable_set(:@runtimes, {'ruby18'=>{'environment'=> {'PATH'=>'/usr/foo','LD_LIBRARY_PATH'=>'bar'}}})
      agent.runtime_env('ruby18').sort.should == ['LD_LIBRARY_PATH=bar','PATH=/usr/foo']
    end
  end

  def create_crashed_app(base_dir)
    apps_dir = create_apps_dir(base_dir)
    File.directory?(apps_dir).should be_true

    inst_dir = File.join(apps_dir, 'test_instance_dir')
    FileUtils.mkdir(inst_dir)
    File.directory?(inst_dir).should be_true

    inst_dir
  end

  def set_crashed_app_state(agent, inst_dir)
    droplets = {
      0 => {
        0 => {
          :dir   => inst_dir,
          :state => :CRASHED,
          :state_timestamp => Time.now.to_i - DEA::Agent::CRASHES_REAPER_TIMEOUT - 60,
        },
      }
    }
    agent.instance_variable_set(:@droplets, droplets)
  end

  def create_apps_dir(base_dir)
    apps_dir = File.join(base_dir, 'apps')
    FileUtils.mkdir(apps_dir)
    apps_dir
  end

  def make_test_agent(overrides={})
    config = {
      'logging'   => {'file' => File.join(UNIT_TESTS_DIR, 'test.log') },
      'intervals' => { 'heartbeat' => 1 },
      'base_dir'  => UNIT_TESTS_DIR,
    }
    config.update(overrides)
    DEA::Agent.new(config)
  end
end
