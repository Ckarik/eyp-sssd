class sssd::ldap(
			$ldap_uri,
			$ldap_chpass_uri=undef,
			$ldap_search_base,
			$ldap_group_search_base=undef,
			$ldap_tls_ca_cert = undef,
			$ldap_schema = 'rfc2307bis',
			$ldap_tls_reqcert = 'demand',
			$ldap_group_member = 'member',
			#$ldap_access_filter = memberOf=cn=...
			#$ldap_access_filter = (|(memberOf=cn=...)(memberOf=cn=...)...)
			$ldap_access_filter=undef,
			$ldap_bind_dn=undef,
			$ldap_bind_dn_password=undef,
			$authconfigbackup='/var/tmp/puppet.authconfig.ldap.backup',
			$filter_users = [ 'root','ldap','named','avahi','haldaemon','dbus','news','nscd' ],
			$sshkeys=true,
			$sudoldap=true,
			$sudoers_order = [ 'files', 'sss' ],
			$ssl='yes',
		) inherits sssd::params
{
	Exec {
		path => '/bin:/sbin:/usr/bin:/usr/sbin',
	}

	validate_array($ldap_uri)

	if($ldap_chpass_uri)
	{
		validate_array($ldap_chpass_uri)
	}

	if($ldap_tls_ca_cert==undef) and ($ldap_tls_reqcert=='demand')
	{
		fail('Incompatible options: ldap_tls_ca_cert undefined, ldap_tls_reqcert demand')
	}

	validate_string($ldap_search_base)

	validate_absolute_path($authconfigbackup)

	if($sudoldap)
	{
		$nsswitch_opts_sudoers=$sudoers_order
	}
	else
	{
		$sudoers_order = [ 'files' ]
	}

	service { 'oddjobd':
		enable  => true,
		ensure  => 'running',
		require => Service['messagebus'],
	}

	exec { 'authconfig backup':
		command => "authconfig --savebackup=$authconfigbackup",
		creates => $authconfigbackup,
		require => [ Package[$sssd::packages] ],
	}

	file { "/etc/sssd/sssd.conf":
		ensure  => present,
		owner   => 'root',
		group   => 'root',
		mode    => '0600',
		require => Exec['authconfig backup'],
		notify  => [Service['sssd'], Exec['authconfig enablesssd']],
		content => template("${module_name}/sssdconf.erb"),
	}

	if($ldap_tls_ca_cert!=undef)
	{
		exec { 'mkdir openldapcerts':
			command => "mkdir -p /etc/openldap/cacerts",
			require => Exec['authconfig backup'],
		}

		file { '/etc/openldap/cacerts':
			ensure  => directory,
			owner   => 'root',
			group   => 'root',
			mode    => '0755',
			require => Exec['mkdir openldapcerts'],
		}

		file { '/etc/openldap/cacerts/sssd.ca':
			ensure  => present,
			owner   => 'root',
			group   => 'root',
			mode    => '0644',
			require => File['/etc/openldap/cacerts'],
			notify  => Exec['cacertdir rehash'],
			source  => $ldap_tls_ca_cert,
		}

		exec { 'cacertdir rehash':
			command      => '/usr/sbin/cacertdir_rehash /etc/openldap/cacerts',
			refreshonly  => true,
			require      => File['/etc/openldap/cacerts/sssd.ca'],
			before 			 => Exec['authconfig enablesssd'],
			notify       => Exec['authconfig enablesssd'],
		}
	}

	exec { 'authconfig enablesssd':
		command     => 'authconfig --enablemkhomedir --enablesssd --enablesssdauth --enablelocauthorize --update',
		require     => [ Service['oddjobd'], File['/etc/sssd/sssd.conf'] ],
		refreshonly => true,
	}

	service { 'sssd':
		enable  => true,
		ensure  => 'running',
		require => Exec['authconfig enablesssd'],
	}

	#passwd shadow group

	class { 'nsswitch':
		passwd   => [ 'files', 'sss' ],
		shadow   => [ 'files', 'sss' ],
		group    => [ 'files', 'sss' ],
		#gshadow => [ 'files', 'sss' ],
		sudoers  => $nsswitch_opts_sudoers,
		notify   => Service['sssd'],
	}

	if($sshkeys)
	{
		package { 'openssh-ldap':
			ensure => 'installed',
			before => Service['sssd'],
		}

		file { '/etc/ssh/ldap.conf':
			owner   => 'root',
			group   => 'sshd',
			mode    => '0640',
			content => template("${module_name}/ldap-sshkeys.erb"),
			require => Package['openssh-ldap'],
			notify  => Service['sssd'],
			before  => Service['sssd'],
		}
	}
}
