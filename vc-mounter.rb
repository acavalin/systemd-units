#!/usr/bin/ruby

require 'yaml'       # config parsing
require 'open3'      # run command with STDIN/OUT access
require 'ostruct'    # hash to object utility
require 'shellwords' # escape strings for the shell

Signal.trap('INT'){} # trap ^C
STDOUT.sync = true   # autoflush

class VCMounter
  ENCRYPTION_ALGORITHMS = %w{
    AES  Camellia  Kuznyechik  Serpent  Twofish
    AES-Twofish  Serpent-AES  Twofish-Serpent
    AES-Twofish-Serpent Serpent-Twofish-AES
  }

  def initialize(cfg_file = 'vc-mounter.yml')
    @cfg  = OpenStruct.new YAML.load_file(cfg_file)
    @cfg.mount_opts ||= 'users,rw,suid,exec,async'
    
    @pass = ' ' * 100
    @pim  = ' ' * 100 # personal iteration number
    @algo = ' ' * 100 # encryption algorithm
  end # initialize -------------------------------------------------------------

  def set_cpu_governor(g); system "echo #{g} | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor"; end
  def set_cpu_max
    @prev_governor = `/usr/bin/cpufreq-info -c 0`.split("\n").grep(/The governor/).first.to_s.sub(/.+"(.+)".+/, '\1')
    @prev_governor = :powersave if @prev_governor.empty?
    set_cpu_governor :performance
  end # set_cpu_max ------------------------------------------------------------
  def set_cpu_prev; set_cpu_governor @prev_governor; end
  
  def run(args)
    exit code: 2, msg: 'you are not root!' if `whoami`.strip != 'root'

    set_cpu_max
    
    case args[0].to_s
      when 'fsck+mount' # system mount
        exit 0 if mount_all(mount: false, keep_pass: true) == :quit

        if (errors = fsck).empty?
          mount_all map: false
          exit 0
        else
          puts "Errors checking volumes filesystems:"
          puts errors.map{|i| "  * #{i}" }
          puts "Leaving volumes MAPPED for inspection"
          `systemd-ask-password "Press ENTER to continue..."`
          exit 2
        end
      
      when 'try-umount' # system umount
        print 'Unmounting all encrypted volumes... '
        exit (dismount_volumes(force: false) || dismount_volumes(force: true)) ?
          {code: 0, msg: 'done.' } : {code: 2, msg: "ERROR!\n#{managed_volumes_list}"}
      
      when 'mount'      # manual mount
        mount_all
        exit 1
      
      when 'umount'     # manual umount
        print 'Unmounting all encrypted volumes... '
        exit dismount_volumes(force: args.include?('force')) ?
          {code: 1, msg: 'done.' } : {code: 2, msg: "ERROR!\n#{managed_volumes_list}"}
      
      else
        exit code: 1, msg: "USAGE: #{File.basename __FILE__} <mount|fsck+mount|umount|try-umount> [force]"
    end
  end # run --------------------------------------------------------------------
  
  # returns :quit if user typed "quit"
  def mount_all(opts = {})
    opts = {map: true, mount: true, keep_pass: false}.merge(opts)

    loop do
      if @pass.strip.empty? # ask password/pim/algo
        @pass = `systemd-ask-password "Enter encrypted volumes password:" `.strip
        @pim  = `systemd-ask-password "Enter encrypted volumes PIM:"      `.strip unless @pass == 'quit'
        #puts "Available encryption algorithms:" + ENCRYPTION_ALGORITHMS.
        #  each_with_index.map{|a, i| %Q|#{"\n" if i%4==0}[#{i}] #{a}|}.join(', ')
        #@algo = `systemd-ask-password "Enter encrypted volumes Algorithm num.:"`.strip.to_i unless [@pass, @pim].include?('quit')
        if [@pass, @pim, @algo].include?('quit')
          puts "NOT mounting as requested."
          break
        end
      end
      
      print "Mounting encrypted volumes (#{opts[:mount] ? 'map+mount' : 'map only' }): "
      mountable_volumes.each{|id, mp| mount_volume id, mp, opts }
      puts " done!"
      
      mounts = managed_volumes_list
      puts mounts
      
      break if mountable_volumes.keys.all?{|id| mounts.match id.to_s }
      
      clear_pass unless opts[:keep_pass]
    end
    
    @pass == 'quit' ? :quit : :ok
  end # mount_all --------------------------------------------------------------
  
  def mount_volume(id, mp, opts = {})
    opts = {map: true, mount: true}.merge(opts)
    
    print '_'
    
    status = volume_status id, mp
    
    if opts[:map] && !status.mapped && !status.mounted
      Open3.popen3(
        "sudo -u #{@cfg.user}" +
        "  #{@cfg.app} -v -k '' --protect-hidden=no --filesystem=none" +
        #"  --encryption=#{ENCRYPTION_ALGORITHMS[@algo]}"+
        "  /dev/disk/by-id/#{id} #{mp.shellescape}"
      ) do |si, so, se|
        si.puts @pass.to_s
        si.puts @pim .to_s
      end
      
      status = volume_status id, mp
      print "\b#{status.mapped ? 'm' : '-'}"
    end
  
    if opts[:mount] && status.mapped && !status.mounted
      system "sudo mount -o #{@cfg.mount_opts} #{status.map_dev} #{mp}"
      status = volume_status id, mp
      print "\b#{status.mounted ? 'M' : '-'}"
    end
    
    # disable sleep timeout for usb drives
    if id.match(/^usb/)
      ris = system("hdparm -q -S 0 #{id.sub /-part.$/, ''} 2> /dev/null")
      print ris ? 'S' : 's'
    end
    
    print "_\b"
    sleep 3
    
    if File.exists?("#{mp}/setup_tchd")
      `/usr/bin/ruby #{mp}/setup_tchd`
      print $?.to_i == 0 ? 'X' : 'x'
    end
  
    print ' '
  end # mount_volume -----------------------------------------------------------
  
  def fsck
    errors   = []
    to_check = {}
  
    puts "Checking all encrypted volumes..."
    puts '-' * 79
    
    existing_volumes.each do |id, mp|
      status = volume_status id, mp
      name   = "#{mp} / #{id} @ #{status.map_dev}"
      
      if status.mapped && !status.mounted
        puts "  * #{name}: to be checked"
        to_check[id] = name
      else
        puts "  * #{name}: unmapped/missing! SKIPPING CHECK!"
        errors << "#{name}: skipped"
      end
    end
    
    # parallel filesytem check
    unless system "fsck -M -a -C0 #{to_check.keys.join ' '}"
      errors << "#{to_check.values.join ', '}: fsck errors"
    end
    
    puts '-' * 79
    
    errors
  end # fsck -------------------------------------------------------------------
  
  def dismount_volumes(opts = {})
    opts = {force: false}.merge(opts)
  
    sleep 0.5
    
    if opts[:force]
      puts "Killing open processes..."
      mounted_volumes.each{|v| system %Q|fuser -vmk #{v.mnt_dir.shellescape}| }
      `#{@cfg.app} --force -d`
    else
      `#{@cfg.app} -d`
    end
    
    sleep 0.5
    
    mounted_volumes.empty?
  end # dismount_volumes -------------------------------------------------------
  
  def clear_pass
    return if @pass.strip.empty? && @pim.strip.empty?
    
    puts "Clearing in-memory pass/pim..."
    # clean password
    @pass.size.times{|i| @pass[i] = rand(100).chr }
    @pim .size.times{|i| @pim[i]  = rand(100).chr }
    #@algo.size.times{|i| @pim[i]  = rand(100).chr }
    @pass = ' ' * 100
    @pim  = ' ' * 100 # personal iteration number
    #@algo = ' ' * 100
    GC.enable
    GC.start
  end # clear_pass -------------------------------------------------------------
  
  def volume_exists?(id, mp)
    File.exists?("/dev/disk/by-id/#{id}") && File.exists?(mp)
  end # volume_exists? ---------------------------------------------------------
  
  def volume_status(id, mp)
    sleep 0.5
    info     = `#{@cfg.app} --volume-properties /dev/disk/by-id/#{id} 2> /dev/null`.split("\n")
    virt_dev = info.grep(/Device/)[0].to_s.split(':')[1].to_s.strip
    mnt_dir  = info.grep(/Mount/ )[0].to_s.split(':')[1].to_s.strip
    OpenStruct.new mapped:  File.exists?(virt_dev),
                   mounted: File.exists?(mnt_dir),
                   map_dev: virt_dev,
                   mnt_dir: mnt_dir
  end # volume_status ----------------------------------------------------------
  
  def existing_volumes
    @cfg.mounts.select{|id, mp| volume_exists? id, mp }
  end # existing_volumes -------------------------------------------------------
  
  def mountable_volumes
    existing_volumes.reject{|id, mp| volume_status(id, mp).mounted }
  end # mountable_volumes ------------------------------------------------------
  
  def mounted_volumes
    existing_volumes.select{|id, mp| volume_status(id, mp).mounted }
  end # mounted_volumes --------------------------------------------------------
  
  def managed_volumes_list
    `#{@cfg.app} -l 2>&1`.gsub(/.dev.disk.by-id./,'').gsub(/^/,'  * ')
  end # managed_volumes_list ---------------------------------------------------
  
  
  private # ____________________________________________________________________
  
  
  def exit(opts = {})
    opts = {code: opts} if opts.is_a?(Fixnum)
    set_cpu_prev
    clear_pass
    puts opts[:msg] if opts[:msg]
    Kernel.exit opts[:code].to_i
  end # exit -------------------------------------------------------------------
end

vcm = VCMounter.new "#{File.dirname(__FILE__)}/vc-mounter.yml"
at_exit do
  vcm.set_cpu_prev
  vcm.clear_pass rescue nil # ensure clear pass at exit without modifying exit status
end
vcm.run ARGV
