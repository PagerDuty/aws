require 'securerandom'

provides :aws_route53_health_check

property :type, String, required: true
property :ip_address, String
property :port, Integer, required: true
property :fqdn, String
property :search_string, String
property :resource_path, String
property :enable_sni, [true, false], default: false
property :request_interval, Integer, default: 30
property :failure_threshold, Integer, default: 3
property :inverted, [true, false], default: false
property :measure_latency, [true,false], default: false
property :check_regions, Array, default: ['us-west-1', 'us-east-1', 'us-west-2']
property :fail_on_error, [true, false], default: false

# the r53 health check API calls this "regions" but calling the
# API region "region" and the health check source regions "regions"
# is confusing, so we prefer "check_regions" but allow "regions"
alias_method :regions, :check_regions
alias_method :fully_qualified_domain_name, :fqdn

# authentication
property :aws_access_key,        String
property :aws_secret_access_key, String, sensitive: true
property :aws_session_token,     String, sensitive: true
property :aws_assume_role_arn,   String
property :aws_role_session_name, String
property :region, String, default: lazy { fallback_region }

include AwsCookbook::Ec2 # needed for aws_region helper

# allow use of the property names from the route53 cookbook
alias_method :aws_access_key_id, :aws_access_key
alias_method :aws_region, :region

action :create do
  # if health check exists
  if health_check_exists(new_resource.name)
    if health_check_modified(new_resource.name)
      converge_by("update health check #{new_resource.name}") do
        id = node['aws']['route53_health_check'][new_resource.name]['check_id']

        # AWS API doesn't allow some fields to be updated. We can't
        # delete-and-recreate with a new type because DNS records might refer
        # to the id of this check.
        check = route53_client.get_health_check({
          health_check_id: id
        })
        current_config = check[:health_check][:health_check_config]

        puts "\n#{current_config}\n"

        if current_config[:type] != new_resource.type
          raise "AWS APIs don't permit changing the 'type' of an existing health check"
        elsif current_config[:request_interval] != new_resource.request_interval
          raise "AWS APIs don't permit changing the 'request_interval' of an existing health check"
        elsif current_config[:measure_latency] != new_resource.measure_latency
          raise "AWS APIs don't permit changing the 'measure_latency' property of an existing health check"
        end

        config = health_check_config
        config[:health_check_id] = id
        [:type, :request_interval, :measure_latency].each { |option| config.delete(option) }

        route53_client.update_health_check(config)
      end
    end
  else
    converge_by("add new health check #{new_resource.name}") do
      # caller_reference is a universally unique reference to this health check. We don't
      # need the protections the API provides around it, AND you can't reuse the caller
      # reference of a deleted health check again ever(!), so random uuid it is
      caller_reference = SecureRandom.uuid

      resp = route53_client.create_health_check(
        caller_reference: caller_reference,
        health_check_config: health_check_config,
      )
      check_id = resp[:health_check][:id]
      tag_health_check(check_id)
      # store id in node so we can delete by name later
      node.normal['aws']['route53_health_check'][new_resource.name]['check_id'] = check_id
      node.normal['aws']['route53_health_check'][new_resource.name]['caller_reference'] = caller_reference
    end
  end
end

action :delete do
  #if health_check_exists(new_resource.name)
    converge_by("remove health check #{new_resource.name}") do
      route53_client.delete_health_check({
        health_check_id: name_to_check_id(new_resource.name)
      })
      node.rm('aws', 'route53_health_check', new_resource.name)
    end
  #end
end

action_class do
  include AwsCookbook::Ec2

  def route53_client
    @route53 ||= begin
      require 'aws-sdk-route53'
      Chef::Log.debug('Initializing Aws::Route53::Client')
      create_aws_interface(::Aws::Route53::Client, region: new_resource.region)
    end
  end

  def name_to_check_id(name)
    node.read('aws', 'route53_health_check', name, 'check_id')
  end

  def health_check_exists(name)
    id = name_to_check_id(name)
    if id
      resp = route53_client.get_health_check({
        health_check_id: id
      })
      if !resp.empty?
        true
      else
        false
      end
    else
      false
    end
  end

  def tag_health_check(id)
    route53_client.change_tags_for_resource({
      add_tags: [
        {
          # "Name" appears in the R53 health check table in console
          key: "Name",
          value: new_resource.name,
        }
      ],
      resource_id: id,
      resource_type: "healthcheck",
    })
  end

  def health_check_config
    config = {
      type: new_resource.type,
      port: new_resource.port,
      enable_sni: new_resource.enable_sni,
      request_interval: new_resource.request_interval,
      failure_threshold: new_resource.failure_threshold,
      inverted: new_resource.inverted,
      measure_latency: new_resource.measure_latency,
      regions: new_resource.check_regions.sort(),
    }
    config[:ip_address] = new_resource.ip_address if new_resource.ip_address
    config[:resource_path] = new_resource.resource_path if new_resource.resource_path
    config[:fully_qualified_domain_name] = new_resource.fqdn if new_resource.fqdn
    config[:search_string] = new_resource.search_string if new_resource.search_string

    config
  end

  def health_check_modified(name)
    resp = route53_client.get_health_check({
      health_check_id: name_to_check_id(name)
    })

    current_config = resp[:health_check][:health_check_config]
    new_config = health_check_config

    args = [:type, :port, :enable_sni, :request_interval, :failure_threshold,
            :inverted, :measure_latency, :regions, :ip_address, :resource_path,
            :fully_qualified_domain_name, :search_string]

    args.each do |arg|
      if current_config[arg] != new_config[arg]
        Chef::Log.info("Health check config modified: #{arg} changed")
        return true
      end
    end

    false
  end
end




