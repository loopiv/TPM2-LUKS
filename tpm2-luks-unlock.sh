#!/bin/bash
# Full disk encryption on Linux using LUKS+TPM2
#
# Heavily modified, but based on:
# https://run.tournament.org.il/ubuntu-18-04-and-tpm2-encrypted-system-disk/
#
# Usage:
# sudo ./tpm2-luks-autounlock.sh [<device path>]
#
# e.g. to use the first device from /etc/crypttab:
# sudo ./tpm2-luks-autounlock.sh
#
# or to specify a device:
# sudo ./tpm2-luks-autounlock.sh /dev/sda3
#
# Updated 2023/05/26
# -Renamed to tpm2-luks-autounlock.sh
# -Now accepts the device as a command line parameter.  If none provided, pulls the first volume from /etc/crypttab and uses that.  Resolves issue #3
# -Added check if running as root rather than using sudo (thanks zombiedk!).  Resolves issue #4
# -Added variable to change the key size.  Defaults to 64 characters
# -Added size parameter to tpm2_nvread calls to avoid warnings during unlock about reading the full index
#
# Updated 2022/04/29
# -Automated comparison of root.key and TPM values
# -Added support for multiple encrypted volumes by using the volume name for the temp file in tpm2-getkey
# -Tested with Ubuntu 22.04.  Works as expected for LVM, but does not work for ZFS encryption
#
# -Added more output
# Created 2020/07/13
# This assumes a fresh Ubuntu 20.04 install that was configured with full disk LUKS encryption at install so it requires a password to unlock the disk at boot.
# This will create a new 64 character random password, add it to LUKS, store it in the TPM, and modify initramfs to pull it from the TPM automatically at boot.

KEYSIZE=64

# Check if running as root
if (( $EUID != 0 )); then
    echo "This script must run with root privileges, e.g.:"
    echo "sudo $0 $1" 
    exit
fi

# If no parameter provided, get the first volume in crypttab and look up the device
if [ "$1" != "" ]
then
    TARGET_DEVICE=$1
else
    CRYPTTAB_VOLUME=$(head --lines=1 /etc/crypttab | awk '{print $1}')
    if [ "${CRYPTTAB_VOLUME}" == "" ]
    then
        echo "No device specified at the command line, and couldn't find one on the first line of /etc/crypttab.  Exiting with no changes made to the system."
        exit
    fi
    TARGET_DEVICE=$(cryptsetup status ${CRYPTTAB_VOLUME} | sed -n -E 's/device:\s+(.*)/\1/p')
fi

if $(cryptsetup isLuks ${TARGET_DEVICE})
then
    echo Using \"${TARGET_DEVICE}\", which appears to be a valid LUKS encrypted device...
else
    echo Device \"${TARGET_DEVICE}\" does not appear to be a valid LUKS encrypted device.  Please specify a device on the command line, e.g.
    echo sudo ./tpm2-luks-autounlock.sh /dev/sda3
    exit
fi

echo
echo Installing tpm2-tools...
echo
apt install tpm2-tools

echo
echo Defining the area on the TPM where we will store a ${KEYSIZE} character key...
echo
tpm2_nvundefine 0x1500016 2> /dev/null
tpm2_nvdefine -s ${KEYSIZE} 0x1500016 > /dev/null

echo
echo Generating a ${KEYSIZE} char alphanumeric key and saving it to root.key...
echo
cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c ${KEYSIZE} > root.key

echo
echo Storing the key in the TPM...
echo
tpm2_nvwrite -i root.key 0x1500016

echo
echo Checking the saved key against the one in the TPM...
echo
tpm2_nvread -s ${KEYSIZE} 0x1500016 2> /dev/null | diff root.key - > /dev/null
if [ $? != 0 ]
then
   echo The root.key file does not match what is stored in the TPM.  Cannot proceed!
   exit
fi

echo
echo Adding the new key to LUKS.  You will need to enter the current passphrase used to unlock the drive...
echo
cryptsetup luksAddKey ${TARGET_DEVICE} root.key
if [ $? != 0 ]
then
    echo Something went wrong adding the encryption key to ${TARGET_DEVICE}. Check /etc/crypttab and/or lsblk to determine your encrypted volume, then update this script with the correct value
    exit
fi

echo
echo Removing root.key file for extra security...
echo
rm root.key

echo
echo Creating a key recovery script and putting it at /usr/local/sbin/tpm2-getkey...
echo
cat << EOF > /tmp/tpm2-getkey
#!/bin/sh
TMP_FILE=".tpm2-getkey.\${CRYPTTAB_NAME}.tmp"

if [ -f "\${TMP_FILE}" ]
then
  # tmp file exists, meaning we tried the TPM this boot, but it didn’t work for the drive and this must be the second
  # or later pass for the drive. Either the TPM is failed/missing, or has the wrong key stored in it.
  /lib/cryptsetup/askpass "Automatic disk unlock via TPM failed for (\${CRYPTTAB_SOURCE}) Enter passphrase: "
  exit
fi

# No tmp, so it is the first time trying the script. Create a tmp file and try the TPM
touch \${TMP_FILE}
tpm2_nvread -s ${KEYSIZE} 0x1500016
EOF

# Move the file, set the ownership and permissions
mv /tmp/tpm2-getkey /usr/local/sbin/tpm2-getkey
chown root: /usr/local/sbin/tpm2-getkey
chmod 750 /usr/local/sbin/tpm2-getkey

echo
echo Creating initramfs hook and putting it at /etc/initramfs-tools/hooks/tpm2-decryptkey...
echo
cat << EOF > /tmp/tpm2-decryptkey
#!/bin/sh
PREREQ=""
prereqs()
 {
     echo "\${PREREQ}"
 }
case \$1 in
 prereqs)
     prereqs
     exit 0
     ;;
esac
. /usr/share/initramfs-tools/hook-functions
copy_exec \`which tpm2_nvread\`
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0.0.0
copy_exec /usr/lib/x86_64-linux-gnu/libtss2-tcti-device.so.0
exit 0
EOF

# Move the file, set the ownership and permissions
mv /tmp/tpm2-decryptkey /etc/initramfs-tools/hooks/tpm2-decryptkey
chown root: /etc/initramfs-tools/hooks/tpm2-decryptkey
chmod 755 /etc/initramfs-tools/hooks/tpm2-decryptkey

echo
echo Backing up /etc/crypttab to /etc/crypttab.bak, then updating it to run tpm2-getkey on decrypt...
echo
# This will only update the first line of /etc/crypttab.  If multiple updates are needed, they must be done manually.
if [ `cat /etc/crypttab | wc -l` -gt 1 ]
then
    echo "This section only update the first line of /etc/crypttab. It seems there are multiple lines, so please update the file manually."
fi
# e.g. this line: sda3_crypt UUID=d4a5a9a4-a2da-4c2e-a24c-1c1f764a66d2 none luks,discard
# should become : sda3_crypt UUID=d4a5a9a4-a2da-4c2e-a24c-1c1f764a66d2 none luks,discard,keyscript=/usr/local/sbin/tpm2-getkey
cp /etc/crypttab /etc/crypttab.bak
sed -i 's%$%,keyscript=/usr/local/sbin/tpm2-getkey%' /etc/crypttab

echo
echo Copying the current initramfs just in case, then updating the initramfs with auto unlocking from the TPM...
echo
cp /boot/initrd.img-`uname -r` /boot/initrd.img-`uname -r`.orig
mkinitramfs -o /boot/initrd.img-`uname -r` `uname -r`

echo
echo
echo
echo At this point you are ready to reboot and try it out!
echo
echo If the drive unlocks as expected, you may optionally remove the original password used to encrypt the drive and rely
echo completely on the random new one stored in the TPM.  If you do this, you should keep a copy of the key somewhere saved on
echo a DIFFERENT system, or printed and stored in a secure location on another system so you can manually enter it at the prompt.
echo To get a copy of your key for backup purposes, run this command:
echo echo \`sudo tpm2_nvread -s ${KEYSIZE} 0x1500016\`
echo
echo If you remove the original password used to encrypt the drive and fail to backup the key in then TPM then experience TPM,
echo motherboard, or another failure preventing auto-unlock, you WILL LOSE ACCESS TO EVERYTHING ON THE DRIVE!
echo If you are SURE you have a backup of the key you put in the TPM, here is the command to remove the original password:
echo sudo cryptsetup luksRemoveKey ${TARGET_DEVICE}
echo
echo If booting fails, press esc at the beginning of the boot to get to the grub menu.  Edit the Ubuntu entry and add .orig to end
echo of the initrd line to boot to the original initramfs this one time.
echo e.g. initrd /initrd.img-5.4.0-40-generic.orig
