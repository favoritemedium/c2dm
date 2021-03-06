require 'httparty'
require 'cgi'
require "notification_helper.rb"
require "c2dm_logger.rb"
require "quota_exceeded_exception.rb"
require "ap"

module C2DM
  # Main class with all notification sending methods.
  class Push
    include HTTParty
    default_timeout 30

    include NotificationHelper

    attr_accessor :timeout

    AUTH_URL = 'https://www.google.com/accounts/ClientLogin'
    PUSH_URL = 'https://android.apis.google.com/c2dm/send'

    # Initialize a instance of Push, and obtain a auth token and remember it to be used later.
    # this method can throw a exception as it does not handle exceptions. Hence where ever this is used
    # you handle any exception thrown
    def initialize(username, password, source)
      C2DM::C2dmLogger.log.debug "Start: initialize Push with [#{username}, #{source}]"
      post_body = "accountType=HOSTED_OR_GOOGLE&Email=#{username}&Passwd=#{password}&service=ac2dm&source=#{source}"
      params = {:body => post_body,
                :headers => {'Content-type' => 'application/x-www-form-urlencoded',
                             'Content-length' => "#{post_body.length}"}}

      response = Push.post(AUTH_URL, params)
      C2DM::C2dmLogger.log.debug "Received response [#{response}]"
      @auth_token = C2DM::Push.extract_authentication_token response
      C2DM::C2dmLogger.log.debug "Received auth_token [#{@auth_token}]"
    end

    # Extract the authentication token from the response received from the C2DM server
    def self.extract_authentication_token httparty_response
      response_split = httparty_response.body.split("\n")
      response_split[2].gsub("Auth=", "")
    end

    # Send a C2DM notification with a set of other parameters and values, as given in the map
    def send_notification_with_kv_map(registration_id, map, handle_exceptions=true)
      begin
        C2DM::C2dmLogger.log.debug "Start: send_notification_with_kv_map with [#{registration_id}, #{map}]"
        post_body = "registration_id=#{registration_id}&collapse_key=foobar&#{self.get_data_string(map)}"
        params = {:body => post_body,
                  :headers => {'Authorization' => "GoogleLogin auth=#{@auth_token}"}}
        return parse_push_response Push.post(PUSH_URL, params)
      rescue Exception => ex
        if handle_exceptions
          C2DM::C2dmLogger.log.fatal result="Exception in send_notification_with_kv_map [exception: #{ex} backtrace: #{ex.backtrace}]"
          result
        else
          raise ex
        end
      end
    end

    # maintain the error and success counts
    def self.manage_counts counts, response
      if response[:response][:is_error]
        counts[:error_count] = counts[:error_count] + 1
      else
        counts[:success_count] = counts[:success_count] + 1
      end
      C2DM::C2dmLogger.log.debug "Counts updated [#{counts}]"
    end

    QUOTA_EXCEEDED_RETRY_INTERVAL = 5 # in seconds

    # Send C2DM notifications with a set of other parameters and values, as given in the map.
    # The notifications array should consists of map objects like:
    # {:registration_id => "x", :key_value_pairs => { :key_one => "value_one", :key_two => "value_two" }}
    # The passed in key value pairs will be sent through C2DM
    def self.send_notifications_with_kv_map(username, password, source, notifications)
      C2DM::C2dmLogger.log.debug "Start: send_notification_with_kv_map with [#{username}, #{password}, #{source}, #{notifications}]"
      responses = []
      exceptions = []
      start_point = 0
      counts = {
          :success_count => 0,
          :error_count => 0,
          :exception_count => 0,
          :timeout_count_consecative => 0,
          :timeout_count => 0,
          :quota_exceeded_count => 0,
          :quota_exceeded_count_consecative => 0
      }

      while true do
        begin
          c2dm = Push.new(username, password, source)
          C2DM::C2dmLogger.log.debug "send_notification_with_kv_map start sending notifications [start_point:#{start_point}, total # of notifications:#{notifications.size}]"
          for i in start_point..notifications.size-1
            start_point = i # update start point, so if something goes wrong when sending this notification, we can restart from this
            notification = notifications[i]
            C2DM::C2dmLogger.log.debug "Sending notification [position:#{i}, notification:#{notification}]"
            response = c2dm.send_notification_with_kv_map(
                notification[:registration_id],
                notification[:key_value_pairs],
                false
            )
            clear_consecative_error_counts counts, response
            process_response i, response, notification, responses
            manage_counts(counts, response)
          end

          C2DM::C2dmLogger.log.debug "Reached the end of notification sending cycle."
          break # everything seems to have worked out fine. break!
        rescue C2DM::QuotaExceededException => ex
          break unless handle_quota_exceeded_exception ex, exceptions, counts
        rescue Timeout::Error, Timeout::ExitException => ex
          break unless handle_timeout_exception ex, exceptions, counts
        rescue Exception => ex
          break unless handle_exception ex, exceptions, counts
        end
      end

      result = {
          :responses => responses,
          :counts => counts,
          :exceptions => exceptions
      }
      C2DM::C2dmLogger.log.debug "send_notification_with_kv_map done. [#{result}]"
      #ap result
      result
    end

    # Handle a general Exception, return true if successfully handled, false if not.
    # right now we always return false
    def self.handle_exception ex, exceptions, counts
      log_exception ex, exceptions
      counts[:exception_count] = counts[:exception_count] +1
      C2DM::C2dmLogger.log.fatal "FATAL Unhandled Exception, giving up [#{ex.class.to_s}, exception:#{ex} backtrace: #{ex.backtrace}]"
      false
    end

    MAX_RETRIES_FOR_TIMEOUT_EX = 4
    # Handle a Timeout Exception, return true if successfully handled, false if not.
    def self.handle_timeout_exception ex, exceptions, counts
      log_exception ex, exceptions
      counts[:timeout_count] = counts[:timeout_count] +1
      counts[:timeout_count_consecative] = counts[:timeout_count_consecative] +1
      C2DM::C2dmLogger.log.warn "#{ex.class.to_s} retrying [count:#{counts[:timeout_count_consecative]}, exception:#{ex} backtrace: #{ex.backtrace}]"
      if counts[:timeout_count_consecative] == MAX_RETRIES_FOR_TIMEOUT_EX + 1 # max retries = X, so break if this is the 4th time
        C2DM::C2dmLogger.log.fatal "FATAL Timeout::Error/Timeout::ExitException, giving up [count:#{counts[:timeout_count_consecative]}, #{ex.class.to_s}, exception:#{ex} backtrace: #{ex.backtrace}]"
        return false
      end
      true
    end

    MAX_RETRIES_FOR_QUOTA_EXCEEDED_EX = 4
    # Handle a Quota Exceeded Exception, return true if successfully handled, false if not.
    def self.handle_quota_exceeded_exception ex, exceptions, counts
      log_exception ex, exceptions
      counts[:quota_exceeded_count] = counts[:quota_exceeded_count] +1
      counts[:quota_exceeded_count_consecative] = counts[:quota_exceeded_count_consecative] +1

      C2DM::C2dmLogger.log.warn "C2DM::QuotaExceededException retrying after #{QUOTA_EXCEEDED_RETRY_INTERVAL} seconds [count:#{counts[:quota_exceeded_count_consecative]}, #{ex.class.to_s}, exception:#{ex} backtrace: #{ex.backtrace}]"

      if counts[:quota_exceeded_count_consecative] == MAX_RETRIES_FOR_QUOTA_EXCEEDED_EX + 1 # max retries = X, so break if this is the (X+1)th time
        C2DM::C2dmLogger.log.fatal "FATAL C2DM::QuotaExceededException, giving up [count:#{counts[:quota_exceeded_count_consecative]}, #{ex.class.to_s}, exception:#{ex} backtrace: #{ex.backtrace}]"
        return false
      end
      sleep QUOTA_EXCEEDED_RETRY_INTERVAL # if retrying, wait for a while before retrying.
      true
    end

    # Process the response received from the C2DM within the context of batch notification sending, and prepare
    # final the return value (responses)
    def self.process_response position, response, notification, responses
      C2DM::C2dmLogger.log.debug "Sending notification result [position:#{position}, notification:#{notification}, result:#{response}]"
      if response[:response][:is_error]
        C2DM::C2dmLogger.log.warn "Sending notification result contains error [position:#{position}, notification:#{notification}, result:#{response}]"
        check_for_and_raise_quota_exceeded_exception response
        responses << {
            :description => response[:response][:description],
            :http_status_code => response[:http_status_code],
            :registration_id => notification[:registration_id],
            :key_value_pairs => notification[:key_value_pairs]
        }
      end
    end

    C2DM_QUOTA_EXCEEDED_ERROR_MESSAGE_DESCRIPTION = "QuotaExceeded"
    # Check for the QuotaExceeded error from the C2DM and raise an exception
    def self.check_for_and_raise_quota_exceeded_exception response
      if response[:response][:description] == C2DM_QUOTA_EXCEEDED_ERROR_MESSAGE_DESCRIPTION
        raise C2DM::QuotaExceededException.new
      end
    end

    # clear consecative error counts
    # this method is called after every successful notification push
    # this insures that we will only give up after X CONSECATIVE errors
    def self.clear_consecative_error_counts(counts, response)
      C2DM::C2dmLogger.log.debug "clear_consecative_error_counts [counts: #{counts} response: #{response}]"
      counts[:timeout_count_consecative] = 0
      counts[:quota_exceeded_count_consecative] = 0 unless response[:response][:description] == C2DM_QUOTA_EXCEEDED_ERROR_MESSAGE_DESCRIPTION
    end

    # log a exception in a useful way
    def self.log_exception ex, ex_collection
      entry={:ex_type => ex.class, :msg => ex.to_s, :trace => ex.backtrace}
      C2DM::C2dmLogger.log.warn entry.to_s
      ex_collection << entry
    end
  end
end