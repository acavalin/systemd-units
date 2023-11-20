#!/usr/bin/env ruby
$VERBOSE    = nil
STDOUT.sync = true

running_as_script = File.basename($0) == File.basename(__FILE__)

%w( yaml fileutils shellwords pathname optparse logger pp ).each{|lib| require lib }

# re-run as root to overcome file permission errors
exec %Q|sudo -E #{File.expand_path __FILE__} #{ARGV.map(&:shellescape).join ' '}| if running_as_script && Process.uid != 0

Signal.trap('INT'){} # trap ^C

class VCMounter
  # https://www.veracrypt.fr/code/VeraCrypt/tree/src/Volume/Hash.cpp
  HASH_ALGOS = %w{ sha256 sha512 whirlpool blake2s streebog }
  
  ENC_ALGOS = %w{
    AES  Camellia  Kuznyechik  Serpent  Twofish
    AES-Twofish  Serpent-AES  Camellia-Serpent  Kuznyechik-AES  Kuznyechik-Twofish  Twofish-Serpent
    AES-Twofish-Serpent Serpent-Twofish-AES  Kuznyechik-Serpent-Camellia
  }

  DEV_CACHE = %w{ /run/shm /dev/shm /tmp }.detect{|d| File.exist? d } + '/vc-mounter'

  ON_RASPI  = File.read('/sys/firmware/devicetree/base/model') =~ /Raspberry Pi/i rescue false
  
  LOG_LEVEL = Logger::WARN # levels: UNKNOWN, FATAL, ERROR, WARN, INFO, DEBUG
  
  def initialize
    at_exit{ self.app_params_clear }
    
    @log = Logger.new STDOUT, level: LOG_LEVEL, formatter: proc{|sev,ts,pn,msg| "#{sev[0..4].ljust 5}: #{msg}\n" }

    cfg_name  = 'vc-mounter.yml'
    cfg_file  = [
      ENV['VCMNT_CFG'],
      cfg_name,
      ".#{cfg_name}",
      "#{ENV['HOME']}/.#{cfg_name}",
      File.join(File.dirname(__FILE__), cfg_name),
      File.join(File.dirname(__FILE__), ".#{cfg_name}"),
      "/tmp/#{cfg_name}"
    ].compact.detect{|f| File.exist?(f) if f }
    die "config file not found! [#{cfg_name}]" unless cfg_file

    cfg_file = File.expand_path cfg_file
    @config  = YAML::load_file cfg_file
    @config['cfg_file'  ] = cfg_file
    
    die "app not found! [#{@config['app']}]" unless File.executable?(@config['app'])
    
    # sanitize mount options
    @config['mount_opts'] = (@config['mount_opts'] || 'users,suid,exec,async,nodiscard').to_s.split(',') - %w{ rw }
    
    # password, personal iteration multiplier, hash algorithm, encryption algorithm
    @params = %w{ pass pim hash enca }.inject({}){|h, k| h.merge k => ' '*100 }
    
    # make a backup of devices links
    FileUtils.mkdir_p DEV_CACHE
    @config['volumes'].to_h.each do |name, props|
      next unless File.exist?(props['mp'])
      
      if File.exist?("/dev/disk/by-id/#{props['dev']}")
        device = File.readlink "/dev/disk/by-id/#{props['dev']}"
        device = "/dev/disk/by-id/#{device}" if Pathname.new(device).relative?
        @config['volumes'][name]['dev_src'  ] = File.expand_path device
        @config['volumes'][name]['dev_cache'] = "#{DEV_CACHE}/#{props['dev']}"
        FileUtils.symlink @config['volumes'][name]['dev_src'], @config['volumes'][name]['dev_cache'], force: true
      elsif File.exist?(props['dev'])
        @config['volumes'][name]['dev_src'  ] = File.expand_path props['dev']
        @config['volumes'][name]['dev_cache'] = "#{DEV_CACHE}/#{File.basename props['dev']}"
        FileUtils.symlink @config['volumes'][name]['dev_src'], @config['volumes'][name]['dev_cache'], force: true
      else
        @config['volumes'][name].merge! 'dev_src' => '[missing]', 'dev_cache' => '[missing]'
      end
    end
    
    Dir.chdir '/' # change to a safe directory
  end # initialize -------------------------------------------------------------

  def run(argv)
    @options = CmdlineParser.parse(argv) rescue die($!, level: :error)
    
    @log.level = Logger.const_get @options[:log_level]
    
    @log.info "config file > #{@config['cfg_file'   ]}"
    debug '@config' => @config, '@options' => @options, '@params' => @params, 'argv' => argv
    
    case argv[0]
    when 'list'  ; volumes_list
    when 'mount' ; volumes_mount
    when 'umount'; volumes_umount
    else           CmdlineParser.parse %w{-h}
    end
  end # run --------------------------------------------------------------------
  
  def app_params_clear
    (@params||{}).keys.each do |k|
      @params[k].size.times{|i| @params[k][i] = rand(100).chr }
      @params[k] = ' '*100
    end
    ObjectSpace.garbage_collect
    nil
  end # app_params_clear -------------------------------------------------------
  
  
  private # ____________________________________________________________________
  
  
  def volumes_umount
    mapped_volumes = volumes_status.            # eventually select the specified volume
      select{|name, props| props['mapped'] && (@options[:volume].blank? || name == @options[:volume]) }
    debug mapped_volumes
    
    puts "NOTICE: no mapped volume/s found" if mapped_volumes.empty?
    
    if @options[:daemon]
      logfile = '/tmp/vc-mounter-daemon.log'
      puts "Running in daemon mode, logs @ #{logfile}"
      Process.daemon
      STDOUT.reopen logfile, 'a'
      STDERR.reopen logfile, 'a'
    end
    
    puts "Dismounting decrypted volumes: syncing..."
    %x| sync | # flush disk writes
    
    mapped_volumes.each do |name, props|
      print " => #{name}: "
      
      # 1. run umount script
      script_name = "#{props['mp']}/enc-hd-umount"
      if props['mounted'] && @options[:scripts] && File.executable?(script_name)
        sleep 1
        ENV['VCMNT_VOLUME'] = props.inspect
        print system(%Q| #{script_name.shellescape} 2>&1 |) ? 'SCRIPT_OK, ' : 'SCRIPT_ERROR, '
        ENV['VCMNT_VOLUME'] = nil
      end # run script
      
      # 2. dismount virtual volume
      dismount_output = %x| #{@config['app']} -t -d #{props['dev_cache'].shellescape} 2>&1 |.strip
      puts $?.to_i == 0 ? 'OK' : dismount_output
      
      # 3. try brute force only when requested and failed umount
      unless @options[:force] && $?.to_i != 0
        spindown_disk props['dev_src']
        next
      end

      if @options[:daemon]
        puts "\n----- #{Time.now.strftime '%F %H:%M'} | #{name} | #{props['dev']} -----"
      else
        puts '    => brute forcing dismount:'
      end
      
      nfs_active  = (`/usr/sbin/exportfs -s 2> /dev/null`.strip.size > 0)
      dbus_active = system %Q| systemctl status dbus.service > /dev/null 2>&1 |
      
      if props['mounted']
        puts '- swapoff files within volume'
        swap_files = `swapon --show=TYPE,NAME --noheadings --raw 2> /dev/null`.split("\n").grep(/^file/).map{|l| l.split(' ')[1] }
        swap_files.each{|f| `swapoff #{f.shellescape}` if f.start_with?(props['mp']) }
        
        if nfs_active
          puts '- stopping NFS shares...'
          `/usr/sbin/exportfs -ua`
        end
        
        if dbus_active
          puts '- stopping DBUS service...'
          system %Q| systemctl stop dbus.service 2>&1 |
        end
        
        puts '- killing open processes ----- first  try -----'
        system %Q| /usr/bin/fuser -vkm #{props['virtual_device'].shellescape} 2>&1 | ; sleep 1
        puts '- killing open processes ----- second try -----'
        system %Q| /usr/bin/fuser -vkm #{props['virtual_device'].shellescape} 2>&1 |
        
        puts '- remount read-only'
        system %Q| /usr/bin/sync ; mount -o remount,ro #{props['virtual_device'].shellescape} 2>&1 |
      end # if mounted
      
      puts '- retry dismount'
      system %Q| #{@config['app']} -t         -d #{props['dev_cache'].shellescape} > /dev/null 2>&1 |
      system %Q| #{@config['app']} -t --force -d #{props['dev_cache'].shellescape}             2>&1 | if $?.to_i != 0
      
      if $?.to_i != 0 && props['map_type'] == 'loop' && File.exist?(props['virtual_device'])
        puts '- detaching loop device'
        system %Q| /usr/sbin/losetup --detach #{props['virtual_device'].shellescape} 2>&1 |
      end
      
      if nfs_active
        puts '- restarting NFS shares...'
        `/usr/sbin/exportfs -ra 2> /dev/null`
      end
      
      if dbus_active
        puts '- restarting DBUS service...'
        system %Q| systemctl start dbus.service 2>&1 |
      end
      
      spindown_disk props['dev_src']
    end # each mapped volume
      
    sleep 1
    system %Q| /usr/sbin/shutdown -h 0 | if @options[:shutdown]
    system %Q| /usr/sbin/shutdown -r 0 | if @options[:reboot  ]
  end # volumes_umount ---------------------------------------------------------
  
  def volumes_mount
    set_cpu_governor_max
    
    # 1. decrypt volumes/map to virtual devices
    mappable_volumes = volumes_status.            # eventually select the specified volume
      select{|name, props| props['mountable'] && (@options[:volume].blank? || name == @options[:volume]) }
    debug mappable_volumes
    if mappable_volumes.any?
      app_params_read # read params only the first time
      print "Decrypting volumes:"
    end
    mappable_volumes.each do |name, props|
      print " #{name}"
      app_cmd = %Q| #{@config['app'].shellescape} \
        -t -v -k '' --protect-hidden=no --filesystem=none \
        #{ '-m nokernelcrypto'                               if props['is_ssd'] || ON_RASPI } \
        #{ "--hash=#{HASH_ALGOS[@params['hash'].to_i]}"      if @params['hash'].present?    } \
        #{ "--encryption=#{ENC_ALGOS[@params['enca'].to_i]}" if @params['enca'].present?    } \
        #{props['dev_cache'].shellescape}  #{props['mp'].shellescape} |
      IO.popen("#{app_cmd} 2> /dev/null", 'r+') do |io|
        io.puts @params['pass']
        io.puts @params['pim' ]
        io.close_write
        io.read # read and discard output
      end # IO.popen
    end
    puts ' done!' if mappable_volumes.any?
    
    mapped_volumes = volumes_status.select{|name, props| props['mapped'] && !props['mounted'] }
    debug mapped_volumes
    
    # 2. fsck virtual devices
    fsck_errors = false
    if mapped_volumes.any? && @options[:fscheck]
      puts "Checking decrypted volumes: #{mapped_volumes.keys.join ' '}"
      puts '-' * 79
      # parallel filesytem check
      dev_list = mapped_volumes.map{|name, props| props['virtual_device'].shellescape }
      unless system("/usr/sbin/fsck -M -a -C0 #{dev_list.join ' '}")
        fsck_errors = true
        puts "Errors checking decrypted volumes!"
        `/usr/bin/systemd-ask-password "Press ENTER to continue..."`
      end
      puts '-' * 79
    end

    # 3. mount virtual devices
    if mapped_volumes.any? && !fsck_errors
      puts "Mounting decrypted volumes:"
      @config['mount_opts'] << 'ro' if @options[:read_only]
      mapped_volumes.each do |name, props|
        print " => #{name}: "
        
        is_mounted = system %Q| /usr/bin/mount \
          -o #{@config['mount_opts'].join(',').shellescape} \
          #{props['virtual_device'].shellescape} \
          #{props['mp'].shellescape} |
        print is_mounted ? "OK" : "ERROR"
        
        # 4. run mount script
        script_name = "#{props['mp']}/enc-hd-mount"
        if is_mounted && @options[:scripts] && File.executable?(script_name)
          print ', '
          sleep 1
          ENV['VCMNT_VOLUME'] = props.inspect
          print system(%Q| #{script_name.shellescape} 2>&1 |) ? 'SCRIPT_OK' : 'SCRIPT_ERROR'
          ENV['VCMNT_VOLUME'] = nil
        end # run script
        
        puts '.'
      end # each mapped volume
    end # mount volumes

    set_cpu_governor_prev
    
    app_params_clear
  end # volumes_mount ----------------------------------------------------------
  
  def volumes_list
    maxl_name = @config['volumes'].keys.map(&:size).max
    maxl_dev  = @config['volumes'].map{|n,p| p['dev'].size }.max
    maxl_mp   = @config['volumes'].map{|n,p| p['mp' ].size }.max
    puts " #{'NAME'.ljust maxl_name} | #{'DEVICE'.ljust maxl_dev} | #{'MOUNT POINT'.ljust maxl_mp}"
    puts "-#{'-'*maxl_name}-+-#{'-'*maxl_dev}-+-#{'-'*maxl_mp}-"
    @config['volumes'].each{|name, props| puts " #{name.ljust maxl_name} | #{props['dev'].ljust maxl_dev} | #{props['mp']}" }
  end # volumes_list -----------------------------------------------------------
  
  def app_params_read
    prompts = {
      'pass' => "Enter encrypted volumes password:",
      'pim'  => "Enter encrypted volumes PIM:",
      'hash' => "HASH: " + HASH_ALGOS.each_with_index.map{|a, i| %Q|[#{i}] #{a}| }.join(', ') + " | Num:",
      'enca' => "ENC: "  + ENC_ALGOS .each_with_index.map{|a, i| %Q|[#{i}] #{a}| }.join(', ') + " | Num:",
    }
    values_abort = %w{ quit  exit  skip  stop    }
    values_retry = %w{ retry again reset restart }
    params_to_read = @params.keys - %w{ enca } # TODO: currently used for volume creation only
    
    loop do
      value = nil
      
      params_to_read.each do |name|
        value   = nil
        value   = @config[name].to_s if @config[name].to_s.present?
        value ||= `/usr/bin/systemd-ask-password #{prompts[name].shellescape}`.strip
        value   = 'retry' if value.blank?
        break if values_abort.include?(value) || values_retry.include?(value)
        @params[name] = value
      end
      
      die "NOT mounting as requested", code: 0 if values_abort.include?(value)
      
      break if params_to_read.all?{|name| @params[name].present? }
    end
    
    nil
  end # app_params_read --------------------------------------------------------
  
  def volumes_status
    # build an info hash from veracrypt properties: {device_basename => info_hash}
    app_info = {}
    `#{@config['app'].shellescape} -t --volume-properties 2> /dev/null`.strip.split(/^$/).each do |text_block|
      info = text_block.strip.split("\n").inject({}){|h, text_line|
        k, v = text_line.split(': ', 2)
        h.merge k.downcase.tr(' -', '__').delete('()') => v
      }
      app_info[ File.basename(info['volume']) ] = info
    end
    
    # merge app info to our volumes configuration
    volumes = @config['volumes'].deep_clone
    volumes.each do |name, props|
      dev_bname = File.basename volumes[name]['dev']
      volumes[name].merge! app_info[dev_bname] if app_info.has_key?(dev_bname)
      volumes[name]['mounted'   ] = Pathname.new(volumes[name]['mp']).mountpoint?
      volumes[name]['mapped'    ] = File.exist? volumes[name]['virtual_device'].to_s
      volumes[name]['map_type'  ] = 'loop'   if volumes[name]['virtual_device'].to_s.start_with?('/dev/loop'  )
      volumes[name]['map_type'  ] = 'mapper' if volumes[name]['virtual_device'].to_s.start_with?('/dev/mapper')
      volumes[name]['mountable' ] = true if !volumes[name]['mounted'] && !volumes[name]['mapped'] && volumes[name]['dev_cache'] &&
                                            File.exist?(volumes[name]['dev_cache']) && File.directory?(volumes[name]['mp'])
      volumes[name]['umountable'] = true if volumes[name]['mapped']
      
      # test if disk is SSD or HDD/file
      if volumes[name]['dev_src'].to_s.start_with?('/dev/')
        # DO NOT USE THE LINUX NATIVE KERNEL CRYPTOGRAPHIC SERVICES TO DISABLE "TRIM"
        # OPERATION ON SSD DRIVES, SEE:
        # - https://www.veracrypt.fr/en/Trim%20Operation.html
        # - http://asalor.blogspot.it/2011/08/trim-dm-crypt-problems.html
        #   - If there is a strong requirement that information about unused
        #     sectors must not be available to attacker, TRIM must be always
        #     disabled.
        #   - TRIM must not be used if there is a hidden device on the disk.
        #     (In this case TRIM would either erase the hidden data or reveal
        #     its position.)
        #   - If TRIM is enabled and executed later (even only once by setting
        #     option and calling fstrim), this operation is irreversible.
        #     Discarded sectors are still detectable even if TRIM is disabled again.
        #   - In specific cases (depends on data patterns) some information
        #     could leak from the ciphertext device.
        #     (In example above you can recognize filesystem type for example.)
        #   - Encrypted disk cannot support functions which rely on returning
        #     zeroes of discarded sectors (even if underlying device announces
        #     such capability).
        #   - Recovery of erased data on SSDs (especially using TRIM) requires
        #     completely new ways and tools.
        #     Using standard recovery tools is usually not successful.
        device_blk = volumes[name]['dev_src']
        device_blk = File.readlink(device_blk) if File.symlink?(device_blk)
        device_blk = File.basename device_blk
        device_blk = device_blk.sub(/(mmc.+)p[0-9]+/i, '\1') if device_blk =~ /^mmc/
        device_blk = device_blk.sub(/([a-z]+).*/i    , '\1') if device_blk =~ /^[sh]d/
        volumes[name]['is_ssd'] = File.read("/sys/block/#{device_blk}/queue/rotational").to_i == 0 rescue true # better safe than sorry
      end # test ssd
    end # each volume
    
    volumes
  end # volumes_status ---------------------------------------------------------
  
  def spindown_disk(device)
    return unless File.blockdev?(device)
    sleep 2
    %x| /usr/sbin/hdparm -y #{device} 2>&1 |
  end # spindown_disk ----------------------------------------------------------
  
  # set cpu governor to "performance"
  def set_cpu_governor_max
    # save current governor
    @config['cpu_governor'] ||= `/usr/bin/cpufreq-info -c 0`.split("\n").grep(/The governor/i).first.to_s.split('"')[1]
    @config['cpu_governor'] = :ondemand if @config['cpu_governor'].blank?
    set_cpu_governor :performance
  end # set_cpu_governor_max ---------------------------------------------------
  
  # restore initial cpu governor
  def set_cpu_governor_prev
    set_cpu_governor @config['cpu_governor']
  end # set_cpu_governor_prev --------------------------------------------------
  
  # set the specified cpu governor to every cpu/core
  def set_cpu_governor(name)
    # intel_pstates is all you need, don't bother changing the governor:
    #   https://bbs.archlinux.org/viewtopic.php?pid=1303796#p1303796
    #   https://plus.google.com/+TheodoreTso/posts/2vEekAsG2QT
    return if `cpufreq-info -c 0 -d`.strip == 'intel_pstate'
    
    `echo #{name} | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`
  end # set_cpu_governor -------------------------------------------------------
  
  # print a message and exit
  def die(msg, options = {})
    options[:code ] ||= 1
    options[:level] ||= :fatal
    @log.send options[:level], msg
    exit options[:code]
  end # die --------------------------------------------------------------------
  
  # print a debug message
  def debug(obj); @log.debug PP.pp(obj, '', 75); end
end# class VCMounter

class CmdlineParser
  LOG_LEVELS = { 'u' => :UNKNOWN, 'f' => :FATAL, 'e' => :ERROR, 'w' => :WARN, 'i' => :INFO, 'd' => :DEBUG }
  
  def self.parse(args, default_opts = {})
    # default option values
    options = {
      force:       false,
      daemon:      false,
      fscheck:     false,
      scripts:     true,
      read_only:   false,
      volume:      nil,
      shutdown:    false,
      reboot:      false,
      log_level:   :WARN,
    }.merge default_opts
    
    optparse = OptionParser.new do |opts|
      progr = File.basename __FILE__

      # Set a banner, displayed at the top of the help screen.
      opts.banner = ''
      
      opts.on('-c', '--check'     , "fsck before mount         def. #{options[:fscheck    ]}"){ options[:fscheck  ] = true  }
      opts.on('-n', '--no-scripts', "do not run scripts        def. #{options[:scripts    ]}"){ options[:scripts  ] = false }
      opts.on('-r', '--read-only' , "mount read only           def. #{options[:read_only  ]}"){ options[:read_only] = true  }
      opts.on('-f', '--force'     , "force umount              def. #{options[:force      ]}"){ options[:force    ] = true  }
      opts.on('-F', '--force-bg'  , "force umount as daemon    def. #{options[:force      ]}"){ options[:force] = options[:daemon] = true }
      opts.on('-S', '--shutdown'  , "*after forced umount      def. #{options[:shutdown   ]}"){ options[:shutdown ] = true  }
      opts.on('-R', '--reboot'    , "*after forced umount      def. #{options[:reboot     ]}"){ options[:reboot   ] = true  }
      opts.on('-v NAME', '--volume NAME', String,
                                    "use this volume only      def. #{options[:volume     ]}"){|v| options[:volume ] = v }
      opts.on('-l LVL', '--log-level LVL', String,
                                    "[e]rr/[w]arn/[i]nf/[d]bg  def. #{options[:log_level  ]}"){|v| options[:log_level ] = LOG_LEVELS[v] if LOG_LEVELS[v] }
      opts.on('-h', '--help'      , "show this help") do
        puts "USAGE: #{progr} [switches] <list|mount|umount>#{opts}"
        exit 1
      end # -h
    end # OptionParser.new
    
    begin
      optparse.parse! args # extract switches and modify args
    rescue SystemExit
      exit 100
    end

    options
  end # self.parse -------------------------------------------------------------
end # class CmdlineParser

# https://github.com/rails/rails/blob/master/activesupport/lib/active_support/core_ext/object/try.rb
module ObjectUtils
  def try(method_name = nil, *args, &b)
    if method_name.nil? && block_given?
      b.arity == 0 ? instance_eval(&b) : yield(self)
    elsif respond_to?(method_name)
      public_send method_name, *args, &b
    end
  end unless nil.respond_to?(:try)
  
  def deep_clone; Marshal.load Marshal.dump(self); end
end # module ObjectUtils

module StringUtils
  def blank?  ; self.to_s.strip.size == 0; end
  def present?; !self.to_s.blank?        ; end
  def no_ts   ; self.to_s.sub(/^\/*/, '').sub(/\/*$/, ''); end # remove trailing slashes
end # module StringUtils

Object  .send :include, ObjectUtils
String  .send :include, StringUtils
NilClass.send :include, StringUtils

VCMounter.new.run ARGV.dup if running_as_script
