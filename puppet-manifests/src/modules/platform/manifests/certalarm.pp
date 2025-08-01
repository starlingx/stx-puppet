class platform::certalarm {
      include ::sysinv::certalarm
}

class platform::certalarm::reload {
      platform::sm::restart {'cert-alarm': }
}
