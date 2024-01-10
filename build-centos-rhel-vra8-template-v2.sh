#!/bin/bash

ID=`id -u`
if [ $ID -ne 0 ]; then
   echo "This command must be run as root or with sudo"
   exit 1
fi

###install cloud-init. ### 
sudo yum install -y cloud-init

###install perl ### 
sudo yum install -y perl perl-File-Temp

###System Update###
sudo yum update -y

# Add any usernames you want to add to /etc/sudoers for passwordless sudo
# users=("cloudadmin")
# for user in "${users[@]}"
# do
# cat /etc/sudoers | grep ^$user
# RC=$?
# if [ $RC != 0 ]; then
# bash -c "echo \"$user ALL=(ALL) NOPASSWD:ALL\" >> /etc/sudoers"
# fi
# done

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

### Disable permanently disable SELinux on your CentOS system
sudo sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

### Disable clean tmp folder. ### 
SOURCE_TEXT="v /tmp 1777 root root 10d"
DEST_TEXT="#v /tmp 1777 root root 10d"
sudo sed -i "s@${SOURCE_TEXT}@${DEST_TEXT}@g" /usr/lib/tmpfiles.d/tmp.conf
sudo sed -i "s/\(^.*10d.*$\)/#\1/" /usr/lib/tmpfiles.d/tmp.conf

### Add After=dbus.service to vmtoolsd. ### 
sudo sed -i '/^After=vgauthd.service/a\After=dbus.service' /usr/lib/systemd/system/vmtoolsd.service

### Disable cloud-init in first boot,we use vmware tools exec customization. ### 
sudo touch /etc/cloud/cloud-init.disabled

### Create a runonce script for re-exec cloud-init. ###
cat <<EOF > /etc/cloud/runonce.sh
#!/bin/bash

  rm -rf /etc/cloud/cloud-init.disabled
  sudo systemctl restart cloud-init.service
  sudo systemctl restart cloud-config.service
  sudo systemctl restart cloud-final.service
  sudo systemctl disable runonce
  sudo touch /tmp/cloud-init.complete
EOF

### Create a runonce service for exec runonce.sh with system after reboot. ### 
cat <<EOF > /etc/systemd/system/runonce.service
[Unit]
Description=Run once
Requires=network-online.target
Requires=cloud-init-local.service
After=network-online.target
After=cloud-init-local.service

[Service]
###wait for vmware customization to complete, avoid executing cloud-init at the first startup.###
ExecStartPre=/bin/sleep 90
ExecStart=/etc/cloud/runonce.sh

[Install]
WantedBy=multi-user.target
EOF

###Create a cleanup script for build vra template. ### 
cat <<EOF > /etc/cloud/clean.sh
#!/bin/bash

# Clear audit logs
if [ -f /var/log/audit/audit.log ]; then
  cat /dev/null > /var/log/audit/audit.log
fi
if [ -f /var/log/wtmp ]; then
  cat /dev/null > /var/log/wtmp
fi
if [ -f /var/log/lastlog ]; then
  cat /dev/null > /var/log/lastlog
fi

# Cleanup persistent udev rules
if [ -f /etc/udev/rules.d/70-persistent-net.rules ]; then
  rm /etc/udev/rules.d/70-persistent-net.rules
fi

# Cleanup /tmp directories
rm -rf /tmp/*
rm -rf /var/tmp/*

# Cleanup current ssh keys
rm -f /etc/ssh/ssh_host_*

# Clear hostname
cat /dev/null > /etc/hostname

# Cleanup apt
sudo yum clean all

# Clean Machine ID
truncate -s 0 /etc/machine-id
rm /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

# Clean cloud-init
cloud-init clean --logs --seed

# Remove any failed login entries
faillock --reset --user root

# Enable our runonce script to re-enable cloud-init (after cust spec runs)
systemctl enable runonce

# Ensure cloud-init is disabled
touch /etc/cloud/cloud-init.disabled

# Cleanup shell history
echo > ~/.bash_history
echo > /root/.bash_history
history -cw

EOF

### Change script execution permissions. ### 
sudo chmod +x /etc/cloud/runonce.sh /etc/cloud/clean.sh

### Reload Systemctl to enable runonce.service. ### 
sudo systemctl daemon-reload

### Enable runonce.service on system boot. ### 
sudo systemctl enable runonce.service

### Clean template. ### 
sudo sh /etc/cloud/clean.sh

###shutdown os. ###
echo "Customizations complete, powering down VM"
shutdown -h now

