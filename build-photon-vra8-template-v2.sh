#!/bin/bash

ID=`id -u`
if [ $ID -ne 0 ]; then
   echo "This command must be run as root or with sudo"
   exit 1
fi

### Update System packages ###
echo "Updating system packages"
tdnf update -y

#### Install system packages (for VMware Customization specs) ###
echo "Install needed system packges"
tdnf install -y cloud-init perl cronie sudo logrotate parted gptfdisk cloud-utils initscripts openssl-c_rehash

### Optional - Disable permanently disable SELinux if enabled
echo "Disabling SELinux if enabled"
if [ -f /etc/selinux/config ]; then
sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
fi

### Add cloud-init directives required for Aria Automation to work properly
echo "Adding cloud-init configurations for Aria Automation"

### Disable vmware_customization in the main cloud.cfg file file that vmtools uses Perl for the customization spec  ###
sudo sed -i 's/^disable_vmware_customization:/#disable_vmware_customization/g' /etc/cloud/cloud.cfg

cat <<EOF > /etc/cloud/cloud.cfg.d/99_aria_automation_config.cfg
#cloud-config

###
### These customizations are required by Aria Automation in order to properly 
### use cloud-config.
###
### disable_vmware_customization: true - Needed to allow the dynamic 
###                                      Customization Spec that Aria 
###                                      Automation to run before cloud-init is
###                                      allowed to execute
### datasource_list: [ OVF ]           - Restricts cloud-init to only listening 
###                                      to OVF datasource to ensure the proper
###                                      configuration is applied
### network: config: disabled          - Prevents cloud-init from ever being 
###                                      able to change the network config
###                                      of the VM (since it is being 
###                                      set/managed by Aria Automation)

disable_vmware_customization: true

datasource_list: [ OVF ]

network:
  config: disabled
EOF

chmod 644 /etc/cloud/cloud.cfg.d/99_aria_automation_config.cfg

### Optional - Allow ssh password auth

cat <<EOF > /etc/cloud/cloud.cfg.d/97_ssh.cfg
#cloud-config

###
### Allow ssh to accept passwords
###
ssh_pwauth: true
EOF

chmod 644 /etc/cloud/cloud.cfg.d/97_ssh.cfg

### Optional - Ensure root account is enabled
cat <<EOF > /etc/cloud/cloud.cfg.d/98_root_user.cfg
# cloud-config

###
### Ensure the root user is not disabled
###
disable_root: false
EOF

chmod 644 /etc/cloud/cloud.cfg.d/98_root_user.cfg

### Optional - disable auto cleaning /tmp folder. ### 
echo "Disabling auto cleanup of /tmp"
sed -i '/^[^#]/ s/\(^.*\s\/tmp\s.*$\)/#\ \1/' /usr/lib/tmpfiles.d/tmp.conf

### Optional - disable auto cleaning /var/tmp folder. ### 
echo "Disabling auto cleanup of /var/tmp"
sed -i '/^[^#]/ s/\(^.*\s\/var\/tmp\s.*$\)/#\ \1/' /usr/lib/tmpfiles.d/tmp.conf

### Add After=dbus.service to vmtoolsd. ### 
echo "Ensure VMware Tools starts after dbus service"
sed -i '/^After=vgauthd.service/a\After=dbus.service' /usr/lib/systemd/system/vmtoolsd.service

### Disable cloud-init initially while Aria Automation runs VMware 
### customization spec
echo "Disable cloud-init initally so that the VMware Customization Spec can safely reboot the system"
touch /etc/cloud/cloud-init.disabled

###Create a runonce script to re-enable cloud-init. ###
echo "Creating the runonce.sh script to launch cloud-init via cron (allows VMware customization spec to finish safely)"
cat <<EOF > /etc/cloud/runonce.sh
#!/bin/bash
sudo rm -rf /etc/cloud/cloud-init.disabled
crontab -r
EOF

### Create a cron job that waits for VMware customization spec to reboot the VM
### 1 time, then execute the runonce.sh defined above
echo "Creating the cronjob to delay cloud-init"
crontab -l | { cat; echo "@reboot ( sudo sh /etc/cloud/runonce.sh )"; } | crontab -

###Create a cleanup script for build vra template. ### 
echo "Creating a script to prepare the VM to become a template"
cat <<EOF > /etc/cloud/clean.sh
#!/bin/bash

# Shrink the log space, remove old logs and truncate logs
logrotate -f /etc/logrotate.conf
rm -f /var/log/*-???????? /var/log/*.gz
if [ -f /var/log/audit/audit.log ]; then
  cat /dev/null > /var/log/audit/audit.log
fi
if [ -f /var/log/wtmp ]; then
  cat /dev/null > /var/log/wtmp
fi
if [ -f /var/log/lastlog ]; then
  cat /dev/null > /var/log/lastlog
fi

# Clean udev rules
if [ -f /etc/udev/rules.d/70-persistent-net.rules ]; then
  rm /etc/udev/rules.d/70-persistent-net.rules
fi

# Clean the /tmp directories
rm -rf /tmp/*
rm -rf /var/tmp/*

# Clean the SSH host keys
rm -f /etc/ssh/ssh_host_*

# Clean the shell history
unset HISTFILE
history -cw
echo > ~/.bash_history
rm -fr /root/.bash_history

# Truncate hostname, hosts, resolv.conf and setting hostname to localhost
truncate -s 0 /etc/{hostname,hosts,resolv.conf}
hostnamectl set-hostname localhost

# Clean tdnf
tdnf clean all

# Clean cloud-init
cloud-init clean -s -l

# Stop cloud-init
systemctl stop cloud-init

# Clean the machine-id
truncate -s 0 /etc/machine-id
rm /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
EOF

### Allow scripts to be executable ### 
chmod +x /etc/cloud/runonce.sh /etc/cloud/clean.sh

###clean template. ### 
echo "Executing the script to prepare the VM"
sh /etc/cloud/clean.sh

###shutdown os. ###
echo "VM prepared - shutting down"
shutdown -h now