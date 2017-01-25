#!/usr/bin/env ruby

require 'choice'
require 'net/https'
require 'uri'
require 'json'

# Enumerate a cluster's hosts via the livestatus API and determine how many are
# healthy.

# TODO: Roll these constants into a ruby gem (nagios-util?)
NAGIOS_OK       = 0
NAGIOS_WARNING  = 1
NAGIOS_CRITICAL = 2
NAGIOS_UNKNOWN  = 3

Choice.options do
  header ''
  header 'Options:'

  option :cluster, :required => true do
    short '-C'
    long  '--cluster'
    desc  '[REQUIRED] The cluster name to check'
  end

  option :critical, :required => true do
    short '-c'
    long  '--critical'
    desc  '[REQUIRED] The critical threshold'
  end

  option :warning, :required => true do
    short '-w'
    long  '--warning'
    desc  '[REQUIRED] The warning threshold'
  end

  footer ''
end

cluster  = Choice.choices[:cluster]
critical = Choice.choices[:critical].to_f
warning  = Choice.choices[:warning].to_f

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

total_nodes = []
total_unhealthy_nodes = []
data_centers = %w[ 1 2 3 4 ]
data_centers.each do |dc|
  # "Filter=groups >= ..."
  livestatus_uri = "https://nagios#{dc}.example.com/livestatus-api/hosts?Filter=groups%20%3E%3D%20#{cluster}_role&Columns=name,state"
  results = get_livestatus_results(livestatus_uri)
  case
  when results.nil?
    #puts "#{dc.upcase}: UNKNOWN NODES"
  when results.empty?
    #puts "#{dc.upcase}: NO NODES"
  else
    results.each do |node|
      total_nodes << node['name']
      if node['state'] > 0
        total_unhealthy_nodes << node['name']
      end
    end
  end
end

# 'percent_healthy' is the number of healthy cluster hosts. We do this so that
# all output reads in a positive manner. For example, if 5% of the hosts are
# down, 95% of the cluster is healthy. All threshold checks will be performed
# against the percentage of healthy hosts.
percent_healthy = 100.0 - ((total_unhealthy_nodes.length.to_f / total_nodes.length).round(2) * 100)

case
when critical > percent_healthy
  puts "The percent of healthy hosts in the '#{cluster}' cluster (#{percent_healthy}%) is less than the critical threshold of #{critical}%!"
  puts "Unhealthy hosts:"
  puts total_unhealthy_nodes.sort.join("\n")
  exit NAGIOS_CRITICAL
when warning > percent_healthy
  puts "The percent of healthy hosts in the '#{cluster}' cluster (#{percent_healthy}%) is less than the warning threshold of #{warning}%!"
  puts "Unhealthy hosts:"
  puts total_unhealthy_nodes.sort.join("\n")
  exit NAGIOS_WARNING
else
  puts "The percent of healthy hosts in the '#{cluster}' cluster (#{percent_healthy}%) is within threshold (Warning: #{warning}% Critical: #{critical}%)"
  puts "NODES: #{total_nodes.sort.join(', ')}"
  exit NAGIOS_OK
end

