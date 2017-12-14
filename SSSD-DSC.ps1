Configuration SSSD {
 
  [CmdletBinding()]
  PARAM ([ValidateSet("RedHat","CentOS","Fedora","Debian","Ubuntu")]
         [string] $Distro='RedHat',
         [string] $FQDN='DOMAIN.YourCompany.NET',
         [IPAddress] $DomainControllerIPaddress=192.168.69.100)

  Import-DscResource -ModuleName nx

  $ADBindUserName='ADBindUser' 

  $base='CN=Users'
  foreach ($dc in $FQDN -Split '\.') {  $base += ",DC=$dc"  }

  $ldap_user_search_base  = $base
  $ldap_group_search_base = $base
  $ldap_default_bind_dn   = "CN=$ADBindUserName,$ldap_user_search_base"


  if ($Distro -in 'RedHat','CentOS','Fedora') {
    $packageManager='yum'
  } else {
    $packageManager='apt'
  }

  nxPackage remove_PAM_LDAP{ 
     Name           = 'pam_ldap'
     Ensure         = 'Absent'
     PackageManager = $packageManager
  }

  nxPackage install_SSSD {
     Name           = 'sssd'
     Ensure         = 'Present'
     PackageManager = $packagemanager
  }


#Configure /etc/sssd/sssd.conf, make it look similar to the below 
#(Note ldap_default_bind_dn and ldap_default_authtok should match your bind user credentials)
$sssd_conf_contents="
[sssd]
config_file_version = 2
reconnection_retries = 3
sbus_timeout = 30
services = nss, pam
domains = $FQDN

[nss]
reconnection_retries = 3

[pam]
reconnection_retries = 3

# Local LAN AD
[domain/$FQDN]
description = AD DC
enumerate = true
min_id = 1000
id_provider = ldap
auth_provider = krb5
chpass_provider = krb5

ldap_uri = ldaps://$DomainControllerIPaddress

# Uncomment below if you are using TLS
ldap_id_use_start_tls = true
ldap_tls_cacert = /etc/ssl/certs/addc.pem

ldap_schema = rfc2307bis
ldap_default_bind_dn = $ldap_default_bind_dn
ldap_default_authtok_type = password
ldap_default_authtok = XXXXXXXXXXXX
ldap_user_search_base = $ldap_user_search_base
ldap_group_search_base = $ldap_group_search_base
ldap_user_object_class = user
ldap_user_name = sAMAccountName
ldap_user_uid_number = uidNumber
ldap_user_gid_number = gidNumber
ldap_user_home_directory = unixHomeDirectory
ldap_user_shell = loginShell
ldap_user_principal = userPrincipalName
ldap_group_object_class = group
ldap_group_gid_number = gidNumber
ldap_force_upper_case_realm = True

krb5_server = $FQDN
krb5_realm = $FQDN
"
    $sssd_conf_contents = $sssd_conf_contents -replace '\n',''  # UNIXify the text
    nxfile SSSDCONF
    { 
        DestinationPath = '/etc/sssd/sssd.conf'
        Owner           = 'root'
        Group           = 'root'
        Mode            = '600'
        Contents        = $sssd_conf_contents
    }



    if ($Distro -in 'RedHat','CentOS','Fedora') {
      #configure PAM to use sssd (RedHat/CentOS only)
      
      nxScript AUTHCONFIG 
      {
        GetScript=@"
#!/bin/bash
authconfig --test
"@
     SetScript=@"
#!/bin/bash
authconfig --enablesssd --enablesssdauth --enablemkhomedir --update
exit 0
"@
     TestScript=@"
#!/bin/bash
if [-e {0}]
then
exit 1
else
exit 0
"@ -f '/etc/sssd/sssd.conf'

      DependsOn="[nxFile]SSSDCONF"
      }

    }
    else  {
      #On Ubuntu/Debian systems, manually edit the following PAM config files and drop in the respective line:
       nxFileLine PAMDcommonauth
       {
         FilePath = "/etc/pam.d/common-auth"
         ContainsLine = '[success=1 default=ignore]	pam_sss.so use_first_pass'
       }

       nxFileLine PAMDcommonaccount
       {
         FilePath = "/etc/pam.d/common-account"
         ContainsLine = '[default=bad success=ok user_unknown=ignore]	pam_sss.so'
       }

       nxFileLine PAMDcommonsession
       {
         FilePath = "/etc/pam.d/common-session"
         ContainsLine = 'session	required        pam_mkhomedir.so umask=0022 skel=/etc/skel'
       }
       nxFileLine PAMDcommonsession2
       {
         FilePath = "/etc/pam.d/common-session"
         ContainsLine = 'session	optional	pam_sss.so'
       }
       nxFileLine PAMDcommonpassword
       {
         FilePath = "/etc/pam.d/common-password"
         ContainsLine = 'password	sufficient			pam_sss.so use_authtok'
       }
    }

<#
Add the AD DC as the primary nameserver into /etc/resolv.conf. You can leave other nameservers, 
just make sure that the following is the first line (changing 192.168.69.100 to the IP address of your internal DNS server. 
If you have multiple servers, duplicate the lines:
#>
    nxFileLine RESOLVECONF
    {
      FilePath = "/etc/resolv.conf"
      ContainsLine = 'nameserver 192.168.69.100'
    }



#disable passwd and group caching in /etc/nscd.conf 
#(otherwise we will have caching conflicts with sssd – some systems may not have ncsd and can ignore this step)
    nxFileLine NSCDCONF
    {
      FilePath = "/etc/nscd.conf"
      ContainsLine = 'enable-cache passwd no'
    }
    nxFileLine NSCDCONF2
    {
      FilePath = "/etc/nscd.conf"
      ContainsLine = 'enable-cache group no'
    }

<#
#Verify that the machine can see AD accounts
getent passwd $ACTIVE_DIRECTORY_USER
# Should see something similar to
YourCompany:*:2000:3000::/home/YourCompany:/bin/bash
id $ACTIVE_DIRECTORY_USER
# Should output something similar to
uid=2000(YourCompany) gid=3000(LinuxAdmins) groups=3000(LinuxAdmins)
#>

}
