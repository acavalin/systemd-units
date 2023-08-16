#!/usr/bin/ruby

# --- USAGE -------------------------------------------------------------------
# vc-mounter.rb               # mount volumes+filesystems
# vc-mounter.rb umount        # umount volumes+filesystems
# vc-mounter.rb umount force  # force umount volumes+filesystems
# vc-mounter.rb fsck+mount    # mount volumes, run fsck, mount filesystems

if `whoami`.strip != 'root'
  puts 'you are not root!'
  exit 2
end

require 'open3'

Signal.trap('INT'){}  # trap ^C

STDOUT.sync = true # autoflush

@vc       = "/opt/myapps/lnx/veracrypt/bin/veracrypt.gui -t"
@dst_user = 'cloud' # user that runs veracrypt
@pass     = ' ' * 100
@pim      = ' ' * 100 # personal iteration number
@to_mount = { # /dev/disk/by-id/KEY => /mnt/MOUNT_POINT
  # TODO: place here your device KEYs and corresponding mount points
}

# updates the list of devices to mount
def existing_mounts
  @to_mount.reject{|id, mp|
    !( File.exists?("/dev/disk/by-id/#{id}") && File.exists?("/mnt/#{mp}") )
  }
end # existing_mounts -------------------------------------------------------

def mountable_mounts
  @to_mount.reject{|id, mp|
    file_esistenti = File.exists?("/dev/disk/by-id/#{id}") && File.exists?("/mnt/#{mp}")
    info   = `#{@vc} --volume-properties /dev/disk/by-id/#{src}`
    device = info.split("\n").grep(/Device/)[0].to_s.split(':')[1].to_s.strip
    montato = info !~ /^Mount.*mnt/ && File.exists?(device)
    #montato = `#{@vc} --volume-properties /dev/disk/by-id/#{id} 2> /dev/null`.strip[0]
    !file_esistenti || montato
  }
end # mountable_mounts ---------------------------------------------------------

# mounts a single volume:
#   mount = true => also mounts the filesystem
def mount_volume(src, dst, mount=true)
  mount_opts = 'users,rw,suid,exec,async'

  print '.'

  # check if volume is already mounted
  info   = `#{@vc} --volume-properties /dev/disk/by-id/#{src}`
  device = info.split("\n").grep(/Device/)[0].to_s.split(':')[1].to_s.strip

  if info !~ /^Mount.*mnt/ && File.exists?(device)
    # volume is already mounted but not the filesystem
    system "mount -o #{mount_opts} #{device} /mnt/#{dst}"
  else
    # volume is not mounted
    cmd = "#{@vc} -v -k \"\" --protect-hidden=no --fs-options=#{mount_opts} "
    cmd += '--filesystem=none ' unless mount
    Open3.popen3("sudo -u #{@dst_user} #{cmd} /dev/disk/by-id/#{src} /mnt/#{dst}") do |si, so, se|
      si.puts @pass.to_s
      si.puts @pim .to_s
    end
  end

  print "\bM"
  
  # disable sleep timeout
  if src.match(/^usb/)
    ris = system("hdparm -q -S 0 #{src.sub /-part.$/, ''} 2> /dev/null")
    print ris ? 'S' : 's'
  end
  
  sleep 3
  
  if File.exists?("/mnt/#{dst}/setup_tchd")
    `/usr/bin/ruby /mnt/#{dst}/setup_tchd`
    print $?.to_i == 0 ? 'X' : 'x'
  end

  print ' '
end # mount_volume ------------------------------------------------------------

# mount all volumes:
#   mount = true => also mounts the filesystem
# returns false if password = "quit", true otherwise
def mount_volumes(options = {})
  opts = {
    :mount   => true,
    :askpwd  => true,
    :wipepwd => true
  }.merge(options)

  # mount volumes
  #`stty -echo`  # disable TTY echo

  # mount and print result
  mounts = ''
  to_mount = mountable_mounts
  while !to_mount.keys.all?{|i| mounts.match i.to_s} do
    if opts[:askpwd]
      @pass = `systemd-ask-password "VeraCrypt volume password: "`.strip
      break if @pass.to_s.strip == 'quit'
      
      @pim  = `systemd-ask-password "VeraCrypt volume PIM: "`.strip
      break if @pim.to_s.strip == 'quit'
    else
      print "\tMounting VeraCrypt volumes: "
    end
    to_mount.each{|dev,dir| mount_volume dev.to_s, dir, opts[:mount]}
    
    sleep 1
    mounts = `#{@vc} -l 2>&1 | sed 's/.*/\\t  * \\0/'`.gsub(/\/dev\/disk\/by-id\//,'')#.split("\n").map{|l| "\t  * #{l}"}.join "\n"
    puts " done! (#{opts[:mount] ? 'volumes+fs' : 'volumes only' })"
    puts "#{mounts}"
    
    to_mount = mountable_mounts
  end

  #`stty echo`  # enable TTY echo
  
  has_quit = @pass.strip == 'quit'

  # clean password
  if opts[:wipepwd]
    @pass.size.times{|i| @pass[i] = (100 * rand).to_i.chr}
    @pim .size.times{|i| @pim[i]  = (100 * rand).to_i.chr}
    @pass = @pim = nil
    GC.enable
    GC.start
  end

  return !has_quit
end # mount_volumes -----------------------------------------------------------

# ritorna true se ci sono dischi ancora montati
def dismount_volumes(options = {})
  opts = {
    :force  => false,
    :rsync  => true,
  }.merge(options)

  # eventual backup
  if opts[:rsync]
    #`sync`
  end

  sleep 0.5
  if opts[:force]
    puts "\tKilling open processes..."
    puts `fuser -vm "/mnt/#{d}"`
    #existing_mounts.values.each{|d| system "fuser -vm \"/mnt/#{d}\""}
    #print "\tKill'em all [y/N]? "
    #if STDIN.gets.strip[0..0] == 'y'
      existing_mounts.values.each{|d| system "fuser -vmk \"/mnt/#{d}\""}
      `#{@vc} --force -d`
    #end
  else
    `#{@vc} -d`
  end
  sleep 1
  `#{@vc} -l 2>&1`.split("\n").grep(/dev.disk/).size > 0
end # dismount_volumes --------------------------------------------------------

def fsck_volumes
  errors = []

  puts "\tChecking all VeraCrypt volumes..."
  puts '-' * 79
  
  devices = existing_mounts.map{|dev, mp|
    info   = `#{@vc} --volume-properties /dev/disk/by-id/#{dev}`
    device = info.split("\n").grep(/Device/)[0].to_s.split(':')[1].strip
    name   = "#{mp} / #{dev} @ #{device}"
    if info !~ /^Mount.*mnt/ && File.exists?(device)
      # volume non montato
      puts " * #{name}: to be checked"
      [name, device]
    else
      # volume montato
      puts " * #{name}: mounted/missing! SKIPPING CHECK!"
      errors << "#{name}: skipped"
      nil
    end
  }.compact
  
  unless system "fsck -M -a -C0 #{devices.map{|i| i[1]}.join ' '}"
    errors << "#{devices.map{|i| i[0]}.join ', '}: fsck errors"
  end
  
  puts '-' * 79
  
  errors
end # fsck_volumes ------------------------------------------------------------


# --- main --------------------------------------------------------------------
case ARGV[0].to_s
  when 'try-umount'
    # umount and eventually force umount
    puts 'Unmounting all VeraCrypt volumes... '

    ris = dismount_volumes(:force => false, :rsync => true)
    ris = dismount_volumes(:force => true , :rsync => true) if ris

    if ris
      puts 'Unmounting all VeraCrypt volumes result: ERROR!'
      exit 2
    else
      puts 'Unmounting all VeraCrypt volumes result: done!'
      exit 0
    end

  when 'umount'
    # umount volumes
    puts 'Unmounting all VeraCrypt volumes... '
    if dismount_volumes(:force => ARGV[1] == 'force', :rsync => true)
      puts 'Unmounting all VeraCrypt volumes result: ERROR!'
      exit 2
    else
      puts 'Unmounting all VeraCrypt volumes result: done!'
      exit 0
    end
  
  when 'fsck+mount'
    if mount_volumes :mount => false, :wipepwd => false
      errors = fsck_volumes
      if errors.size == 0
        mount_volumes :askpwd => false
        exit 0
      else
        puts "\tErrors checking VeraCrypt filesystems:"
        puts errors.map{|i| "\t  * #{i}"}.join("\n")
        `systemd-ask-password "Press ENTER to continue..."`
        dismount_volumes :rsync => false
        exit 2
      end
    else
      puts "NOT mounting as requested."
      exit 0
    end
  
  else # mount
    puts "NOT mounting as requested." unless mount_volumes
    exit 1
end
