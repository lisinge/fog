require File.expand_path(File.join(File.dirname(__FILE__), '..', 'aws'))

module Fog
  module AWS
    class ELB < Fog::Service

      class IdentifierTaken < Fog::Errors::Error; end
      class InvalidInstance < Fog::Errors::Error; end
      class Throttled       < Fog::Errors::Error; end

      requires :aws_access_key_id, :aws_secret_access_key
      recognizes :region, :host, :path, :port, :scheme, :persistent

      request_path 'fog/aws/requests/elb'
      request :configure_health_check
      request :create_app_cookie_stickiness_policy
      request :create_lb_cookie_stickiness_policy
      request :create_load_balancer
      request :create_load_balancer_listeners
      request :delete_load_balancer
      request :delete_load_balancer_listeners
      request :delete_load_balancer_policy
      request :deregister_instances_from_load_balancer
      request :describe_instance_health
      request :describe_load_balancers
      request :disable_availability_zones_for_load_balancer
      request :enable_availability_zones_for_load_balancer
      request :register_instances_with_load_balancer
      request :set_load_balancer_listener_ssl_certificate
      request :set_load_balancer_policies_of_listener

      model_path 'fog/aws/models/elb'
      model      :load_balancer
      collection :load_balancers
      model      :policy
      collection :policies
      model      :listener
      collection :listeners

      class Mock

        def self.data
          @data ||= Hash.new do |hash, region|
            owner_id = Fog::AWS::Mock.owner_id
            hash[region] = Hash.new do |region_hash, key|
              region_hash[key] = {
                :owner_id => owner_id,
                :load_balancers => {}
              }
            end
          end
        end

        def self.dns_name(name, region)
          "#{name}-#{Fog::Mock.random_hex(8)}.#{region}.elb.amazonaws.com"
        end

        def self.reset
          @data = nil
        end

        def initialize(options={})
          @aws_access_key_id = options[:aws_access_key_id]

          @region = options[:region] || 'us-east-1'

          unless ['ap-northeast-1', 'ap-southeast-1', 'eu-west-1', 'us-east-1', 'us-west-1', 'us-west-2'].include?(@region)
            raise ArgumentError, "Unknown region: #{@region.inspect}"
          end
        end

        def data
          self.class.data[@region][@aws_access_key_id]
        end

        def reset_data
          self.class.data[@region].delete(@aws_access_key_id)
        end
      end

      class Real

        # Initialize connection to ELB
        #
        # ==== Notes
        # options parameter must include values for :aws_access_key_id and
        # :aws_secret_access_key in order to create a connection
        #
        # ==== Examples
        #   elb = ELB.new(
        #    :aws_access_key_id => your_aws_access_key_id,
        #    :aws_secret_access_key => your_aws_secret_access_key
        #   )
        #
        # ==== Parameters
        # * options<~Hash> - config arguments for connection.  Defaults to {}.
        #   * region<~String> - optional region to use, in ['eu-west-1', 'us-east-1', 'us-west-1', 'us-west-2', 'ap-northeast-1', 'ap-southeast-1']
        #
        # ==== Returns
        # * ELB object with connection to AWS.
        def initialize(options={})
          require 'fog/core/parser'

          @aws_access_key_id      = options[:aws_access_key_id]
          @aws_secret_access_key  = options[:aws_secret_access_key]
          @connection_options     = options[:connection_options] || {}
          @hmac = Fog::HMAC.new('sha256', @aws_secret_access_key)

          options[:region] ||= 'us-east-1'
          @host = options[:host] || case options[:region]
          when 'ap-northeast-1'
            'elasticloadbalancing.ap-northeast-1.amazonaws.com'
          when 'ap-southeast-1'
            'elasticloadbalancing.ap-southeast-1.amazonaws.com'
          when 'eu-west-1'
            'elasticloadbalancing.eu-west-1.amazonaws.com'
          when 'us-east-1'
            'elasticloadbalancing.us-east-1.amazonaws.com'
          when 'us-west-1'
            'elasticloadbalancing.us-west-1.amazonaws.com'
          when 'us-west-2'
            'elasticloadbalancing.us-west-2.amazonaws.com'
          else
            raise ArgumentError, "Unknown region: #{options[:region].inspect}"
          end
          @path       = options[:path]        || '/'
          @persistent = options[:persistent]  || false
          @port       = options[:port]        || 443
          @scheme     = options[:scheme]      || 'https'
          @connection = Fog::Connection.new("#{@scheme}://#{@host}:#{@port}#{@path}", @persistent, @connection_options)
        end

        def reload
          @connection.reset
        end

        private

        def request(params)
          idempotent  = params.delete(:idempotent)
          parser      = params.delete(:parser)

          body = Fog::AWS.signed_params(
            params,
            {
              :aws_access_key_id  => @aws_access_key_id,
              :hmac               => @hmac,
              :host               => @host,
              :path               => @path,
              :port               => @port,
              :version            => '2011-04-05'
          }
          )

          response = @connection.request({
            :body       => body,
            :expects    => 200,
            :headers    => { 'Content-Type' => 'application/x-www-form-urlencoded' },
            :idempotent => idempotent,
            :host       => @host,
            :method     => 'POST',
            :parser     => parser
          })
        rescue Excon::Errors::HTTPStatusError => error
          if match = error.message.match(/<Code>(.*)<\/Code>(?:.*<Message>(.*)<\/Message>)?/m)
            case match[1]
            when 'CertificateNotFound'
              raise Fog::AWS::IAM::NotFound.slurp(error, match[2])
            when 'LoadBalancerNotFound'
              raise Fog::AWS::ELB::NotFound.slurp(error, match[2])
            when 'DuplicateLoadBalancerName'
              raise Fog::AWS::ELB::IdentifierTaken.slurp(error, match[2])
            when 'InvalidInstance'
              raise Fog::AWS::ELB::InvalidInstance.slurp(error, match[2])
            when 'Throttling'
              raise Fog::AWS::ELB::Throttled.slurp(error, match[2])
            else
              raise
            end
          else
            raise
          end
        end
      end
    end
  end
end
