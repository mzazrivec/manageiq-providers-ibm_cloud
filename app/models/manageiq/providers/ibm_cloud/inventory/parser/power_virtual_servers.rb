class ManageIQ::Providers::IbmCloud::Inventory::Parser::PowerVirtualServers < ManageIQ::Providers::IbmCloud::Inventory::Parser
  require_nested :CloudManager
  require_nested :NetworkManager
  require_nested :StorageManager

  attr_reader :img_to_arch, :subnet_to_ext_ports

  OS_MIQ_NAMES_MAP = {
    'aix'    => 'unix_aix',
    'ibmi'   => 'ibm_i',
    'redhat' => 'linux_redhat',
    'rhel'   => 'linux_redhat',
    'sles'   => 'linux_suse'
  }.freeze

  def initialize
    @img_to_arch         = {}
    @subnet_to_ext_ports = {}
  end

  def parse
    availability_zones
    images
    flavors
    cloud_volume_types
    volumes
    instances
    networks
    sshkeys
  end

  def instances
    collector.vms.each do |instance|
      # saving general VMI information
      ps_vmi = persister.vms.build(
        :availability_zone => persister.availability_zones.lazy_find(persister.cloud_manager.uid_ems),
        :description       => _("PVM Instance"),
        :ems_ref           => instance["pvmInstanceID"],
        :flavor            => persister.flavors.lazy_find(instance["sysType"]),
        :location          => _("unknown"),
        :name              => instance["serverName"],
        :vendor            => "ibm",
        :connection_state  => "connected",
        :raw_power_state   => instance["status"],
        :uid_ems           => instance["pvmInstanceID"],
        :format            => instance["storageType"]
      )

      # saving hardware information (CPU, Memory, etc.)
      ps_hw = persister.hardwares.build(
        :vm_or_template  => ps_vmi,
        :cpu_total_cores => instance['virtualCores']['assigned'],
        :cpu_type        => img_to_arch[instance['imageID']],
        :memory_mb       => instance["memory"] * 1024,
        :guest_os        => OS_MIQ_NAMES_MAP[instance['osType']]
      )

      # saving instance disk information
      instance["volumeIDs"].each do |vol_id|
        volume = collector.volume(vol_id)
        name, disk_type, size = volume&.values_at("name", "diskType", "size")
        persister.disks.build(
          :hardware        => ps_hw,
          :device_name     => name,
          :device_type     => disk_type,
          :controller_type => "ibm",
          :backing         => persister.cloud_volumes.find(vol_id),
          :location        => vol_id,
          :size            => size&.gigabytes
        )
      end

      # saving OS information
      persister.operating_systems.build(
        :vm_or_template => ps_vmi,
        :product_name   => OS_MIQ_NAMES_MAP[instance['osType']],
        :version        => instance['operatingSystem']
      )

      # saving exteral network ports
      external_ports = instance["networks"].reject { |net| net["externalIP"].blank? }
      external_ports.each do |ext_port|
        net_id = ext_port['networkID']
        subnet_to_ext_ports[net_id] ||= []
        subnet_to_ext_ports[net_id] << ext_port
      end

      # saving processor type and amount
      persister.vms_and_templates_advanced_settings.build(
        :resource     => ps_vmi,
        :name         => 'entitled_processors',
        :display_name => _('Entitled Processors'),
        :description  => _('The number of entitled processors assigned to the VM'),
        :value        => instance['processors'],
        :read_only    => true
      )

      # saving processor type
      persister.vms_and_templates_advanced_settings.build(
        :resource     => ps_vmi,
        :name         => 'processor_type',
        :display_name => _('Processor type'),
        :description  => _('dedicated: Dedicated, shared: Uncapped shared, capped: Capped shared'),
        :value        => instance['procType'],
        :read_only    => true
      )
    end
  end

  def images
    collector.images.each do |ibm_image|
      id = ibm_image['imageID']
      arch = ibm_image['specifications']['architecture']
      if ibm_image['specifications']['endianness'] == 'little-endian'
        arch << 'le'
      end
      img_to_arch[id] = arch

      ps_image = persister.miq_templates.build(
        :uid_ems            => id,
        :ems_ref            => id,
        :name               => ibm_image['name'],
        :description        => ibm_image['description'],
        :location           => "unknown",
        :vendor             => "ibm",
        :raw_power_state    => "never",
        :template           => true,
        :storage_profile_id => persister.cloud_volume_types.lazy_find(ibm_image["storageType"]),
        :format             => ibm_image["storageType"]
      )

      persister.operating_systems.build(
        :vm_or_template => ps_image,
        :product_name   => OS_MIQ_NAMES_MAP[ibm_image['specifications']['operatingSystem']]
      )
    end
  end

  def volumes
    collector.volumes.each do |vol|
      persister.cloud_volumes.build(
        :availability_zone => persister.availability_zones.lazy_find(persister.cloud_manager.uid_ems),
        :ems_ref           => vol['volumeID'],
        :name              => vol['name'],
        :status            => vol['state'],
        :bootable          => vol['bootable'],
        :creation_time     => vol['creationDate'],
        :description       => _('IBM Cloud Block-Storage Volume'),
        :volume_type       => vol['diskType'],
        :size              => vol['size']&.gigabytes,
        :multi_attachment  => vol['shareable']
      )
    end
  end

  def networks
    collector.networks.each do |network|
      persister_cloud_networks = persister.cloud_networks.build(
        :ems_ref => "#{network['networkID']}-#{network['type']}",
        :name    => "#{network['name']}-#{network['type']}",
        :cidr    => "",
        :enabled => true,
        :status  => 'active'
      )

      persister_cloud_subnet = persister.cloud_subnets.build(
        :cloud_network     => persister_cloud_networks,
        :cidr              => network['cidr'],
        :ems_ref           => network['networkID'],
        :gateway           => network['gateway'],
        :name              => network['name'],
        :status            => "active",
        :dns_nameservers   => network['dnsServers'],
        :ip_version        => '4',
        :network_protocol  => 'IPv4',
        :availability_zone => persister.availability_zones.lazy_find(persister.cloud_manager.uid_ems),
        :network_type      => network['type']
      )

      mac_to_port = {}

      collector.ports(network['networkID']).each do |port|
        vmi_id = port.dig('pvmInstance', 'pvmInstanceID')

        persister_network_port = persister.network_ports.build(
          :name        => port['portID'],
          :ems_ref     => port['portID'],
          :status      => port['status'],
          :mac_address => port['macAddress'],
          :device_ref  => vmi_id,
          :device      => persister.vms.lazy_find(vmi_id)
        )

        mac_to_port[port['macAddress']] = persister_network_port

        persister.cloud_subnet_network_ports.build(
          :network_port => persister_network_port,
          :address      => port['ipAddress'],
          :cloud_subnet => persister_cloud_subnet
        )
      end

      external_ports = subnet_to_ext_ports[network['networkID']] || []
      external_ports.each do |port|
        port_ps = mac_to_port[port['macAddress']]

        persister.cloud_subnet_network_ports.build(
          :network_port => port_ps,
          :address      => port['externalIP'],
          :cloud_subnet => persister_cloud_subnet
        )
      end
    end
  end

  def sshkeys
    collector.sshkeys.each do |tkey|
      tenant_key = {
        :creationDate => tkey['creationDate'],
        :name         => tkey['name'],
        :sshKey       => tkey['sshKey'],
      }

      # save the tenant instance
      persister.auth_key_pairs.build(:name => tenant_key[:name])
    end
  end

  def flavors
    collector.system_pool.each do |v|
      persister.flavors.build(
        :type    => "ManageIQ::Providers::IbmCloud::PowerVirtualServers::CloudManager::SystemType",
        :ems_ref => v['type'],
        :name    => v['type']
      )
    end
  end

  def cloud_volume_types
    # get only the active storage
    collector.storage_types.each do |v|
      next unless v['state'] == 'active'

      persister.cloud_volume_types.build(
        :type        => "ManageIQ::Providers::IbmCloud::PowerVirtualServers::StorageManager::CloudVolumeType",
        :ems_ref     => v['type'],
        :name        => v['type'],
        :description => v['description']
      )
    end
  end

  def availability_zones
    # Single availability zone per PowerVS Cloud Manager
    persister.availability_zones.build(
      :name    => persister.cloud_manager.name,
      :ems_ref => persister.cloud_manager.uid_ems
    )
  end
end
