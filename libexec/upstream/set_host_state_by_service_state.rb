#!/usr/bin/env ruby

require 'choice'
require 'net/https'
require 'uri'
require 'json'

# Set a host's state based on the worst state of all of its services.
# This is useful for setting the state of a cluster's virtual host as a means
# to indicate that the cluster is experiencing one or more issues.

NAGIOS_OK       = 0
NAGIOS_WARNING  = 1
NAGIOS_CRITICAL = 2
NAGIOS_UNKNOWN  = 3

# NOTE: Nagios maps the exit codes to either UP or DOWN for host objects.
# See 'Host State Determination' at
# https://assets.nagios.com/downloads/nagioscore/docs/nagioscore/3/en/hostchecks.html
# If this script encounters any services in a WARNING state, it will exit as
# CRITICAL so that we can indicate a non-OK issue (WARNING can mean UP *or* DOWN
# depending on the value of 'use_aggressive_host_checking' in the Nagios config).
# We prefer to be unambiguous; we'll output the context that one or more services
# are in a WARNING state so the operator has proper information.

Choice.options do
  header ''
  header 'Options:'

  option :hostname, :required => true do
    short '-h'
    long  '--hostname'
    desc  '[REQUIRED] The hostname name to check'
  end

  footer ''
end

hostname  = Choice.choices[:hostname]

def get_livestatus_results(livestatus_uri)
  uri = URI.parse(livestatus_uri)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  begin
    request = Net::HTTP::Get.new(uri.request_uri)
  rescue => e
    puts "ERROR: #{e.message}"
    return nil
  end

  response = http.request(request)
  if response.code.to_i > 200
    return nil
  else
    json = JSON.parse(response.body)
  end

  if json['success'] == false
    return nil
  end

  return json['content']

end

# We'll ask for a list of columns that will tell us the count of services
# in various states.
service_state_counts = %w[
  num_services
  num_services_crit
  num_services_ok
  num_services_unknown
  num_services_warn
]

# TODO: Update the URI to dynamically determine itself depending on where it's
# running.
livestatus_uri = "https://nagios.example.com/livestatus-api/hosts?Filter=name%20%3D%20#{hostname}&Columns=#{service_state_counts.join(',')}"
results = get_livestatus_results(livestatus_uri)
case
when results.nil?
  puts "Received *nil* response from Livestatus! Can't determine the state of this host's services. Requested #{livestatus_uri}"
  exit NAGIOS_UNKNOWN
when results.empty?
  puts "Received *empty* response from Livestatus! Can't determine the state of this host's services. Requested #{livestatus_uri}"
  exit NAGIOS_UNKNOWN
else
  num_services = results[0]['num_services']
  num_services_crit = results[0]['num_services_crit']
  num_services_ok = results[0]['num_services_ok']
  num_services_unknown = results[0]['num_services_unknown']
  num_services_warn = results[0]['num_services_warn']
  if num_services == num_services_ok
    puts "All of this host's services are OK."
    exit NAGIOS_OK
  else
    case
    when num_services_unknown > 0
      num_services_unknown > 1 ? printf("There are #{num_services_unknown} services") : printf("There is #{num_services_unknown} service")
      puts " in an UNKNOWN state!"
      exit NAGIOS_UNKNOWN
    when num_services_crit > 0
      num_services_crit > 1 ? printf("There are #{num_services_crit} services") : printf("There is #{num_services_crit} service")
      puts " in a CRITICAL state!"
      exit NAGIOS_CRITICAL
    when num_services_warn > 0
      num_services_warn > 1 ? printf("There are #{num_services_warn} services") : printf("There is #{num_services_warn} service")
      puts " in a WARNING state!"
      exit NAGIOS_CRITICAL # Exit as CRITICAL to map to HOST DOWN.
    else
      puts "Can't determine the state of this host's services! Something is really wrong with this check... Requested #{livestatus_uri}"
      exit NAGIOS_UNKNOWN
    end
  end
end

