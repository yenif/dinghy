$LOAD_PATH << File.dirname(__FILE__)+"/thor-0.19.1/lib"
require 'thor'

class DinghyCLI < Thor
  desc "up", "start the Docker VM and NFS service"
  def up
    vagrant = Vagrant.new
    unfs = Unfs.new
    vagrant.up
    unfs.up
    vagrant.mount(unfs)
    vagrant.install_docker_keys
    CheckEnv.new.run
  end

  desc "halt", "stop the VM and NFS"
  def halt
    Vagrant.new.halt
    Unfs.new.halt
  end

  desc "destroy", "stop and delete all traces of the VM"
  def destroy
    halt
    Vagrant.new.destroy
  end
end

require 'pathname'
require 'fileutils'
require 'timeout'
require 'socket'

BREW = Pathname.new(`brew --prefix`.strip)
DINGHY = Pathname.new(File.realpath(__FILE__)) + "../.."
VAGRANT = BREW+"var/dinghy/vagrant"
HOST_IP = "192.168.42.1"

class Unfs
  def up
    halt

    FileUtils.ln_s(plist_path, plist_install_path)
    unless system("launchctl", "load", plist_install_path)
      raise("Could not start the NFS daemon.")
    end

    wait_for_unfs
  end

  def wait_for_unfs
    Timeout.timeout(20) do
      puts "Waiting for NFS daemon..."
      begin
        TCPSocket.open("192.168.42.1", 19321)
      rescue Errno::ECONNREFUSED
        sleep 1
      end
    end
  end

  def halt
    if File.exist?(plist_install_path)
      puts "Stopping NFS daemon..."
      system("launchctl", "unload", plist_install_path)
      FileUtils.rm(plist_install_path)
    end
  end

  def mount_dir
    ENV.fetch("HOME")
  end

  def plist_install_path
    "#{ENV.fetch("HOME")}/Library/LaunchAgents/dinghy.unfs.plist"
  end

  def plist_path
    BREW+"var/dinghy/dinghy.unfs.plist"
  end
end

class Vagrant
  def up
    check_for_vagrant
    cd

    system "vagrant up"
    if command_failed
      raise("There was an error bringing up the Vagrant box. Dinghy cannot continue.")
    end
  end

  def check_for_vagrant
    `vagrant --version`
    if command_failed
      puts <<-EOS
Vagrant is not installed. Please install Vagrant before continuing.
https://www.vagrantup.com
      EOS
    end
  end

  def mount(unfs)
    cd
    puts "Mounting NFS #{unfs.mount_dir}"
    system "vagrant", "ssh", "--", "sudo mount -t nfs #{HOST_IP}:#{unfs.mount_dir} #{unfs.mount_dir} -o nfsvers=3,tcp,mountport=19321,port=19321,nolock,hard,intr"
    if command_failed
      raise("Failed mounting NFS share.")
    end
  end

  def halt
    cd
    system "vagrant halt"
  end

  def destroy
    cd
    system "vagrant destroy"
  end

  def install_docker_keys
    cd
    FileUtils.mkdir_p(key_dir)
    %w[key.pem ca.pem cert.pem].each do |cert|
      target = key_dir+cert
      puts "Writing #{target}"
      contents = `vagrant ssh -- cat .docker/#{cert}`
      if command_failed
        raise("Error contacting the vagrant instance.")
      end
      File.open(target, "wb") { |f| f.write contents }
    end
  end

  def command_failed
    !$?.success?
  end

  def cd
    Dir.chdir(VAGRANT)
  end

  def key_dir
    Pathname.new("#{ENV.fetch("HOME")}/.dinghy/certs")
  end
end

class CheckEnv
  def run
    if expected.all? { |name,value| ENV[name] == value }
      puts "Your environment variables are already set correctly."
    else
      puts "To connect the Docker client to the Docker daemon, please set:"
      expected.each { |name,value| puts "    export #{name}=#{value}" }
    end
  end

  def expected
    {
      "DOCKER_HOST" => "tcp://127.0.0.1:2376",
      "DOCKER_CERT_PATH" => "#{ENV.fetch("HOME")}/.dinghy/certs",
      "DOCKER_TLS_VERIFY" => "1",
    }
  end
end