class ManageIQ::Providers::IbmCloud::PowerVirtualServers::StorageManager::CloudVolume < ::CloudVolume
  supports :create
  supports_not :snapshot_create
  supports_not :update

  def available_vms
    availability_zone.vms.select { |vm| vm.format == volume_type }
  end

  def self.params_for_create(ems)
    {
      :fields => [
        {
          :component  => 'text-field',
          :name       => 'size',
          :id         => 'size',
          :label      => _('Size (in bytes)'),
          :type       => 'number',
          :step       => 1024 * 1024 * 1024,
          :isRequired => true,
          :validate   => [{:type => 'required'}],
        },
        {
          :component => 'select',
          :name      => 'volume_type',
          :id        => 'volume_type',
          :label     => _('Cloud Volume Type'),
          :condition => {
            :when => 'edit',
            :is   => false,
          },
          :options   => ems.cloud_volume_types.map do |cvt|
            {
              :label => cvt.description,
              :value => cvt.name,
            }
          end,
        },
        {
          :component => 'switch',
          :name      => 'multi_attachment',
          :id        => 'multi_attachment',
          :label     => _('Shareable'),
          :onText    => _('Yes'),
          :offText   => _('No'),
        },
        {
          :component    => 'select',
          :name         => 'affinity_policy',
          :id           => 'affinity_policy',
          :label        => _('Affinity Policy'),
          :initialValue => 'off',
          :condition    => {
            :when => 'edit',
            :is   => false,
          },
          :options      => [
            {
              :label => 'Off',
              :value => 'off',
            },
            {
              :label => 'Affinity',
              :value => 'affinity',
            },
            {
              :label => 'Anti-affinity',
              :value => 'anti-affinity',
            },
          ],
        },
        {
          :component  => 'select',
          :name       => 'affinity_volume_id',
          :id         => 'affinity_volume_id',
          :label      => _('Affinity Volume'),
          :isRequired => true,
          :validate   => [{:type => 'required'}],
          :condition  => {
            :and => [
              {
                :not => {
                  :when => 'affinity_policy',
                  :is   => 'off',
                },
              },
              {
                :when => 'edit',
                :is   => false,
              },
            ],
          },
          :options    => ems.cloud_volumes.map do |cv|
            {
              :value => cv.id,
              :label => cv.name,
            }
          end,
        },
      ],
    }
  end

  def self.validate_create_volume(ext_management_system)
    validate_volume(ext_management_system)
  end

  def self.raw_create_volume(ext_management_system, options)
    volume_params = {
      'name'     => options[:name],
      'size'     => options[:size],
      'diskType' => options[:volume_type]
    }

    volume = nil
    ext_management_system.with_provider_connection(:service => 'PowerIaas') do |power_iaas|
      volume = power_iaas.create_volume(volume_params)
    end
    {:ems_ref => volume['volumeID'], :status => volume['state'], :name => volume['name']}
  rescue => e
    _log.error("volume=[#{volume_params}], error: #{e}")
    raise MiqException::MiqVolumeCreateError, e.to_s, e.backtrace
  end

  def validate_delete_volume
    msg = validate_volume
    return {:available => msg[:available], :message => msg[:message]} unless msg[:available]
    if status == "in-use"
      return validation_failed(_("Delete Volume"), _("Can't delete volume that is in use."))
    end

    {:available => true, :message => nil}
  end

  def raw_delete_volume
    ext_management_system.with_provider_connection(:service => 'PowerIaas') do |power_iaas|
      power_iaas.delete_volume(ems_ref)
    end
  rescue => e
    _log.error("volume=[#{name}], error: #{e}")
  end

  def validate_attach_volume
    msg = validate_volume_available
    return {:available => msg[:available], :message => msg[:message]} unless msg[:available]

    if status == "in-use" && !multi_attachment
      return validation_failed(_("Attach Volume"), _("Can't attach non-shareable volume that is in use."))
    end

    {:available => true, :message => nil}
  end

  def raw_attach_volume(vm_ems_ref, _device = nil)
    ext_management_system.with_provider_connection(:service => 'PowerIaas') do |power_iaas|
      power_iaas.attach_volume(vm_ems_ref, ems_ref)
    end
  rescue => e
    _log.error("volume=[#{name}], error: #{e}")
    raise MiqException::MiqVolumeAttachError, _("Unable to attach volume: %{error_message}") % {:error_message => e.message}
  end

  def validate_detach_volume
    validate_volume_in_use
  end

  def raw_detach_volume(vm_ems_ref)
    ext_management_system.with_provider_connection(:service => 'PowerIaas') do |power_iaas|
      power_iaas.detach_volume(vm_ems_ref, ems_ref)
    end
  rescue => e
    _log.error("volume=[#{name}], error: #{e}")
    raise MiqException::MiqVolumeDetachError, _("Unable to detach volume: %{error_message}") % {:error_message => e.message}
  end
end
