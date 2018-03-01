### LINKS
* https://www.digitalocean.com/community/tutorials/systemd-essentials-working-with-services-units-and-the-journal
* https://www.google.it/?gws_rd=ssl#q=systemd%20how%20to%20create%20a%20service
* https://coreos.com/docs/launching-containers/launching/getting-started-with-systemd/

### SETUP:
* `ln -f /opt/systemd-units/name.service /lib/systemd/system/` - **hard link it**
* `systemctl enable name.service`
* `systemctl daemon-reload` - **after some changes**

### REFERENCES:
* http://www.freedesktop.org/software/systemd/man/systemd.service.html
* http://www.freedesktop.org/software/systemd/man/systemd.unit.html
* http://www.freedesktop.org/software/systemd/man/systemd.special.html
* http://www.freedesktop.org/software/systemd/man/bootup.html

Note that `DefaultDependencies = true` implies:

* `Requires  = sysinit.target             `
* `After     = sysinit.target basic.target`
* `Conflicts = shutdown.target            `
* `Before    = shutdown.target            `

### [EARLY START](http://lists.freedesktop.org/archives/systemd-devel/2010-September/000225.html)
> [Unit]
> DefaultDependencies = no
> Requires  = sysinit.target local-fs.target
> After     = sysinit.target local-fs.target
> Before    = basic.target
> [Install]
> WantedBy  = basic.target

### ONESHOTs: this combination stops the execution of both Start and Stop
> Type = oneshot
> RemainAfterExit = yes

### DEBUG E LOGS:
* `journalctl`
* `cat /var/log/boot.log`
* graphs:
    * `systemd-analyze plot > boot-chart.svg                       `
    * `systemd-analyze           dot | dot -Tsvg > boot-full.svg   `
    * `systemd-analyze --order   dot | dot -Tsvg > boot-order.svg  `
    * `systemd-analyze --require dot | dot -Tsvg > boot-require.svg`
