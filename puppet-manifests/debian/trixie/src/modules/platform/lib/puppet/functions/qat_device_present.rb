# Returns true if a QAT device (4940, 4942 or 4946) is present.
#
# Implemented as a Puppet function (not a custom Facter fact) so that the
# underlying lspci probe is only executed when a manifest actually needs the
# value (i.e. when platform::devices is compiled on AIO/worker nodes), rather
# than eagerly on every puppet apply during Facter fact gathering.
Puppet::Functions.create_function(:qat_device_present) do
  dispatch :detect do
    return_type 'Boolean'
  end

  def detect
    !!system('/usr/bin/lspci -n | grep -E "4940|4942|4946" > /dev/null 2>&1')
  end
end
