#!/usr/bin/ruby

require 'yaml'       # config parsing
require 'open3'      # run command with STDIN/OUT access
require 'ostruct'    # hash to object utility
require 'shellwords' # escape strings for the shell
require 'fileutils'  # symlinks & mkdir_p utils
require 'pathname'   # mountpoint?

Signal.trap('INT'){} # trap ^C
STDOUT.sync = true   # autoflush

class VCMounter
  HASH_ALGOS = %w{ sha256 sha512 whirlpool ripemd160 streebog }
  
  ENC_ALGOS = %w{
    AES  Camellia  Kuznyechik  Serpent  Twofish
    AES-Twofish  Serpent-AES  Camellia-Serpent  Kuznyechik-AES  Kuznyechik-Twofish  Twofish-Serpent
    AES-Twofish-Serpent Serpent-Twofish-AES  Kuznyechik-Serpent-Camellia
  }

  DEV_CACHE = %w{ /run/shm /dev/shm /tmp }.detect{|d| File.exists?(d) } + '/vc-mounter'

  ON_RASPI = File.read('/sys/firmware/devicetree/base/model') =~ /Raspberry Pi/i rescue false

  def initialize(cfg_file = 'vc-mounter.yml')
    @cfg  = OpenStruct.new YAML.load_file(cfg_file)
    @cfg.mount_opts ||= 'users,rw,suid,exec,async,nodiscard'
    
    # make a backup of the devices links
    FileUtils.mkdir_p DEV_CACHE
    Dir.chdir('/dev/disk/by-id/') do
      @cfg.mounts.
        select{|id, mp| File.exists?(id) && File.exists?(mp) }.
        each do |id, mp|
          d = File.expand_path File.readlink("/dev/disk/by-id/#{id}")
          FileUtils.symlink d, "#{DEV_CACHE}/#{id}", force: true
        end
    end

    @pass = ' ' * 100
    @pim  = ' ' * 100 # personal iteration multiplier
    @algo = ' ' * 100 # encryption algorithm
    @hash = ' ' * 100 # hash algorithm
  end # initialize -------------------------------------------------------------

  def set_cpu_governor(g)
    # intel_pstates is all you need, don't bother changing the governor:
    #   https://bbs.archlinux.org/viewtopic.php?pid=1303796#p1303796
    #   https://plus.google.com/+TheodoreTso/posts/2vEekAsG2QT
    return if `cpufreq-info -c 0 -d`.strip == 'intel_pstate'

    `echo #{g} | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`
  end
  def set_cpu_max
    @prev_governor = `/usr/bin/cpufreq-info -c 0`.split("\n").grep(/The governor/).first.to_s.sub(/.+"(.+)".+/, '\1')
    @prev_governor = :ondemand if @prev_governor.empty?
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

        ris = (dismount_volumes(force: false) || dismount_volumes(force: true)) ?
          {code: 0, msg: 'done.' } : {code: 2, msg: "ERROR!\n#{managed_volumes_list}"}

        if ON_RASPI
          # veracrypt and systemd doesn't play well together on raspi during shutdown
          # (no volumes are listed) so we try to manually dismount all mounted mountpoints:
          `sync`
          puts ''
          existing_volumes.each do |id, mp|
            next unless Pathname.new(mp).mountpoint? # true if mounted
            puts "ENFORCING UMOUNT OF: #{mp} @ #{id}"
            `fuser -vmk #{mp.shellescape}` # kill everything running inside
            `umount #{mp.shellescape}`
          end
          `losetup --detach-all` # reset all /dev/loop* devices
          `sync`
        end

        exit ris
      
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

        msg = "HASH: " + HASH_ALGOS.each_with_index.map{|a, i| %Q|[#{i}] #{a}|}.join(', ') + " | Num:"
        @hash = `systemd-ask-password "#{msg}"`.strip unless [@pass, @pim].include?('quit')

        #msg = "ENC: " + ENC_ALGOS.each_with_index.map{|a, i| %Q|[#{i}] #{a}|}.join(', ') + " | Num:"
        #@algo = `systemd-ask-password "#{msg}"`.strip unless [@pass, @pim, @hash].include?('quit')

        if [@pass, @pim, @hash, @algo].include?('quit')
          puts "NOT mounting as requested."
          break
        end
      end
      
      print "Mounting encrypted volumes (#{opts[:mount] ? 'map+mount' : 'map only' }): "
      mountable_volumes.each{|id, mp| mount_volume id, mp, opts }
      puts " done!"
      
      mounts = managed_volumes_list
      puts mounts
      
      #break if mountable_volumes.keys.all?{|id| mounts.match id.to_s }
      if mountable_volumes.keys.all?{|id| mounts.match id.to_s }
        clear_pass unless opts[:keep_pass]
        break
      end
      
      # not all volumes are mounted, ask a new pass and retry
      clear_pass
    end
    
    @pass == 'quit' ? :quit : :ok
  end # mount_all --------------------------------------------------------------
  
  def mount_volume(id, mp, opts = {})
    opts = {map: true, mount: true}.merge(opts)
    
    print '_'
    
    status = volume_status id, mp
    
    if opts[:map] && !status.mapped && !status.mounted
      # DO NOT USE THE LINUX NATIVE KERNEL CRYPTOGRAPHIC SERVICES TO DISABLE "TRIM"
      # OPERATION ON SSD DRIVES, SEE:
      #  - https://www.veracrypt.fr/en/Trim%20Operation.html
      #  - http://asalor.blogspot.it/2011/08/trim-dm-crypt-problems.html
      #    - If there is a strong requirement that information about unused sectors must not be available to attacker, TRIM must be always disabled.
      #    - TRIM must not be used if there is a hidden device on the disk. (In this case TRIM would either erase the hidden data or reveal its position.)
      #    - If TRIM is enabled and executed later (even only once by setting option and calling fstrim), this operation is irreversible.
      #      Discarded sectors are still detectable even if TRIM is disabled again.
      #    - In specific cases (depends on data patterns) some information could leak from the ciphertext device.
      #      (In example above you can recognize filesystem type for example.)
      #    - Encrypted disk cannot support functions which rely on returning zeroes of discarded sectors (even if underlying device announces such capability).
      #    - Recovery of erased data on SSDs (especially using TRIM) requires completely new ways and tools.
      #      Using standard recovery tools is usually not successful.
      device_blk = File.basename File.readlink("#{DEV_CACHE}/#{id}")
      device_blk = device_blk.sub(/(mmc.+)p[0-9]+/i, '\1') if device_blk =~ /^mmc/
      device_blk = device_blk.sub(/([a-z]+).*/i, '\1') if device_blk =~ /^[sh]d/
      is_ssd = File.read("/sys/block/#{device_blk}/queue/rotational").to_i == 0
      
      Open3.popen3([
        "sudo -u #{@cfg.user}",
        "  #{@cfg.app} -v -k '' --protect-hidden=no --filesystem=none",
        (' -m nokernelcrypto'                     if is_ssd || ON_RASPI       ),
        (" --hash=#{HASH_ALGOS[@hash.to_i]}"      if @hash.to_s.strip.size > 0),
        (" --encryption=#{ENC_ALGOS[@algo.to_i]}" if @algo.to_s.strip.size > 0),
        "  #{DEV_CACHE}/#{id} #{mp.shellescape}",
      ].compact.join(' ')) do |si, so, se|
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
    
    # managed by /etc/hdparm.conf
    ## disable sleep timeout for usb drives
    #if id.match(/^usb/)
    #  ris = system("hdparm -q -S 0 #{id.sub /-part.$/, ''} 2> /dev/null")
    #  print ris ? 'S' : 's'
    #end
    
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
    to_check = []
  
    puts "Checking all encrypted volumes..."
    puts '-' * 79
    
    existing_volumes.each do |id, mp|
      status = volume_status id, mp
      name   = "#{mp} / #{id} @ #{status.map_dev}"
      
      if status.mapped && !status.mounted
        puts "  * #{name}: to be checked"
        to_check << status.map_dev
      else
        puts "  * #{name}: unmapped/missing! SKIPPING CHECK!"
        errors << "#{name}: skipped"
      end
    end
    
    # parallel filesytem check
    unless system "fsck -M -a -C0 #{to_check.join ' '}"
      errors << "fsck encountered some problems"
    end
    
    puts '-' * 79
    
    errors
  end # fsck -------------------------------------------------------------------
  
  def dismount_volumes(opts = {})
    opts = {force: false}.merge(opts)

    sleep 0.5

    # swapoff any swap file within mounted volumes
    sw_files = `sudo swapon | grep " file " | cut -f 1 -d " "`.strip.split("\n")
    mounted_volumes.each do |id, mp|
      sw_files.each{|f| system "sudo swapoff #{f.shellescape}" if f.include?(mp) }
    end
    
    if opts[:force]
      puts "Killing open processes..."
      `exportfs -ua` # stop NFS server
      mounted_volumes.each{|id, mp| system %Q|fuser -vmk #{mp.shellescape}| }
      `#{@cfg.app} -d`
      `#{@cfg.app} --force -d` # if $?.to_i != 0
      `exportfs -ra` # restart NFS server
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
    @hash.size.times{|i| @hash[i] = rand(100).chr }
    @algo.size.times{|i| @pim[i]  = rand(100).chr }
    @pass = ' ' * 100
    @pim  = ' ' * 100 # personal iteration number
    @hash = ' ' * 100
    @algo = ' ' * 100
    GC.enable
    GC.start
  end # clear_pass -------------------------------------------------------------
  
  def volume_exists?(id, mp)
    File.exists?("#{DEV_CACHE}/#{id}") && File.exists?(mp)
  end # volume_exists? ---------------------------------------------------------
  
  def volume_status(id, mp)
    sleep 0.5
    info     = `#{@cfg.app} --volume-properties #{DEV_CACHE}/#{id} 2> /dev/null`.split("\n")
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
    `#{@cfg.app} -l 2>&1`.gsub("#{DEV_CACHE}/",'').gsub(/^/,'  * ')
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
