# Returns true if an Intel N3000 processing accelerator (FEC) device is present.
#
# Implemented as a Puppet function (not a custom Facter fact) so that the
# underlying lspci probe is only executed when a manifest actually needs the
# value (i.e. when platform::devices is compiled on AIO/worker nodes), rather
# than eagerly on every puppet apply during Facter fact gathering.
#
# Look for vendor Intel=8086 and device N3000=0b30 with accelerator class.
Puppet::Functions.create_function(:n3000_device_present) do
  dispatch :detect do
    return_type 'Boolean'
  end

  def detect
    !!system('/usr/bin/lspci -Dm -d 8086:0b30 | grep -qi accelerator')
  end
end
