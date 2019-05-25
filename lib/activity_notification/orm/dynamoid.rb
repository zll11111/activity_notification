require 'dynamoid/adapter_plugin/aws_sdk_v3'

# Entend Dynamoid to support none, limit, exists?, update_all in Dynamoid::Criteria::Chain.
# ActivityNotification project will try to contribute these fundamental functions to Dynamoid upstream.
# @private
module Dynamoid # :nodoc: all
  # https://github.com/Dynamoid/dynamoid/blob/master/lib/dynamoid/criteria.rb
  # @private
  module Criteria
    # @private
    class None < Chain
      def ==(other)
        other.is_a?(None)
      end

      def records
        []
      end

      def count
        0
      end

      def delete_all
      end

      def empty?
        true
      end
    end

    # https://github.com/Dynamoid/dynamoid/blob/master/lib/dynamoid/criteria/chain.rb
    # @private
    class Chain
      def none
        Chain.new(self.source)
      end

      # Set query result limit as record_limit of Dynamoid
      # @scope class
      # @param [Integer] limit Query result limit as record_limit
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def limit(limit)
        record_limit(limit)
      end

      # Return if records exist
      # @scope class
      # @return [Boolean] If records exist
      def exists?
        record_limit(1).count > 0
      end

      # Return size of records as count
      # @scope class
      # @return [Integer] Size of records
      def size
        count
      end

      #TODO Make this batch
      def update_all(conditions = {})
        each do |document|
          document.update_attributes(conditions)
        end
      end
    end

    # https://github.com/Dynamoid/dynamoid/blob/master/lib/dynamoid/criteria.rb
    # @private
    module ClassMethods
      %i[none].each do |meth|
        define_method(meth) do |*args, &blk|
          chain = Dynamoid::Criteria::Chain.new(self)
          if args
            chain.send(meth, *args, &blk)
          else
            chain.send(meth, &blk)
          end
        end
      end
    end
  end
end

# Entend Dynamoid to support query and scan with 'null' and 'not_null' conditions
# @private
module Dynamoid # :nodoc: all
  # @private
  module Criteria
    # @private
    class Chain
      # @private
      def range_hash(key)
        name, operation = key.to_s.split('.')
        val = type_cast_condition_parameter(name, query[key])

        case operation
        when 'gt'
          { range_greater_than: val }
        when 'lt'
          { range_less_than: val }
        when 'gte'
          { range_gte: val }
        when 'lte'
          { range_lte: val }
        when 'between'
          { range_between: val }
        when 'begins_with'
          { range_begins_with: val }
        when 'null'
          { null: val }
        when 'not_null'
          { not_null: val }
        end
      end

      # @private
      def field_hash(key)
        name, operation = key.to_s.split('.')
        val = type_cast_condition_parameter(name, query[key])

        hash = case operation
               when 'ne'
                 { ne: val }
               when 'gt'
                 { gt: val }
               when 'lt'
                 { lt: val }
               when 'gte'
                 { gte: val }
               when 'lte'
                 { lte: val }
               when 'between'
                 { between: val }
               when 'begins_with'
                 { begins_with: val }
               when 'in'
                 { in: val }
               when 'contains'
                 { contains: val }
               when 'not_contains'
                 { not_contains: val }
               when 'null'
                 { null: val }
               when 'not_null'
                 { not_null: val }
               end

        { name.to_sym => hash }
      end
    end
  end

  # @private
  module AdapterPlugin
    # @private
    class AwsSdkV3

      NULL_OPERATOR_FIELD_MAP = {
        null:         'NULL',
        not_null:     'NOT_NULL'
      }.freeze

      # @private
      class Query < ::Dynamoid::AdapterPlugin::Query
        # @private
        def query_filter
          conditions.except(*AwsSdkV3::RANGE_MAP.keys).reduce({}) do |result, (attr, cond)|
            if AwsSdkV3::NULL_OPERATOR_FIELD_MAP.has_key?(cond.keys[0])
              condition = { comparison_operator: AwsSdkV3::NULL_OPERATOR_FIELD_MAP[cond.keys[0]] }
            else
              condition = {
                comparison_operator: AwsSdkV3::FIELD_MAP[cond.keys[0]],
                attribute_value_list: AwsSdkV3.attribute_value_list(AwsSdkV3::FIELD_MAP[cond.keys[0]], cond.values[0].freeze)
              }
            end
            result[attr] = condition
            result
          end
        end
      end

      # @private
      class Scan < ::Dynamoid::AdapterPlugin::Scan
        # @private
        def scan_filter
          conditions.reduce({}) do |result, (attr, cond)|
            if AwsSdkV3::NULL_OPERATOR_FIELD_MAP.has_key?(cond.keys[0])
              condition = { comparison_operator: AwsSdkV3::NULL_OPERATOR_FIELD_MAP[cond.keys[0]] }
            else
              condition = {
                comparison_operator: AwsSdkV3::FIELD_MAP[cond.keys[0]],
                attribute_value_list: AwsSdkV3.attribute_value_list(AwsSdkV3::FIELD_MAP[cond.keys[0]], cond.values[0].freeze)
              }
            end
            result[attr] = condition
            result
          end
        end
      end
    end
  end
end

module ActivityNotification
  module DynamoidExtension
    extend ActiveSupport::Concern

    class_methods do
      # Defines delete_all method as calling delete_table and create_table methods
      def delete_all
        delete_table
        create_table(sync: true)
      end
    end

    # Defines update method as update_attributes method
    def update(attributes)
      update_attributes(attributes)
    end
  end
    
  module Association
    extend ActiveSupport::Concern

    class_methods do
      # Defines has_many association with ActivityNotification models.
      # @return [Dynamoid::Criteria::Chain] Database query of associated model instances
      def has_many_records(name, options = {})
        has_many_composite_xdb_records name, options
      end

      # Defines polymorphic belongs_to association using composite key with models in other database.
      def belongs_to_composite_xdb_record(name, _options = {})
        association_name     = name.to_s.singularize.underscore
        composite_field = "#{association_name}_key".to_sym
        field composite_field, :string

        self.instance_eval do
          define_method(name) do |reload = false|
            reload and self.instance_variable_set("@#{name}", nil)
            if self.instance_variable_get("@#{name}").blank?
              composite_key = self.send(composite_field)
              if composite_key.present? && (class_name = composite_key.split(ActivityNotification.config.composite_key_delimiter).first).present?
                object_class = class_name.classify.constantize
                self.instance_variable_set("@#{name}", object_class.where(id: composite_key.split(ActivityNotification.config.composite_key_delimiter).last).first)
              end
            end
            self.instance_variable_get("@#{name}")
          end

          define_method("#{name}=") do |new_instance|
            if new_instance.present?
              self.send("#{composite_field}=", "#{new_instance.class.name}#{ActivityNotification.config.composite_key_delimiter}#{new_instance.id}")
            end
            self.instance_variable_set("@#{name}", nil)
          end

          define_method("#{association_name}_type") do
            composite_key = self.send(composite_field)
            composite_key.present? ? composite_key.split(ActivityNotification.config.composite_key_delimiter).first : nil
          end

          define_method("#{association_name}_id") do
            composite_key = self.send(composite_field)
            composite_key.present? ? composite_key.split(ActivityNotification.config.composite_key_delimiter).last : nil
          end
        end
      end

      # Defines polymorphic has_many association using composite key with models in other database.
      # @todo Add dependent option
      def has_many_composite_xdb_records(name, options = {})
        association_name     = options[:as] || name.to_s.underscore
        composite_field = "#{association_name}_key".to_sym
        object_name          = options[:class_name] || name.to_s.singularize.camelize
        object_class         = object_name.classify.constantize

        self.instance_eval do
          # Set default reload arg to true since Dynamoid::Criteria::Chain is stateful on the query
          define_method(name) do |reload = true|
            reload and self.instance_variable_set("@#{name}", nil)
            if self.instance_variable_get("@#{name}").blank?
              new_value = object_class.where(composite_field => "#{self.class.name}#{ActivityNotification.config.composite_key_delimiter}#{self.id}")
              self.instance_variable_set("@#{name}", new_value)
            end
            self.instance_variable_get("@#{name}")
          end
        end
      end
    end
  end
end

# Entend Dynamoid to support ActivityNotification scope in Dynamoid::Criteria::Chain
# @private
module Dynamoid # :nodoc: all
  # https://github.com/Dynamoid/dynamoid/blob/master/lib/dynamoid/criteria.rb
  # @private
  module Criteria
    # https://github.com/Dynamoid/dynamoid/blob/master/lib/dynamoid/criteria/chain.rb
    # @private
    class Chain
      # Selects all notification index.
      #   ActivityNotification::Notification.all_index!
      # is defined same as
      #   ActivityNotification::Notification.group_owners_only.latest_order
      # @scope class
      # @example Get all notification index of the @user
      #   @notifications = @user.notifications.all_index!
      #   @notifications = @user.notifications.group_owners_only.latest_order
      # @param [Boolean] reverse If notification index will be ordered as earliest first
      # @param [Boolean] with_group_members If notification index will include group members
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def all_index!(reverse = false, with_group_members = false)
        target_index = with_group_members ? self : group_owners_only
        reverse ? target_index.earliest_order : target_index.latest_order
      end

      # Selects unopened notification index.
      #   ActivityNotification::Notification.unopened_index
      # is defined same as
      #   ActivityNotification::Notification.unopened_only.group_owners_only.latest_order
      # @scope class
      # @example Get unopened notificaton index of the @user
      #   @notifications = @user.notifications.unopened_index
      #   @notifications = @user.notifications.unopened_only.group_owners_only.latest_order
      # @param [Boolean] reverse If notification index will be ordered as earliest first
      # @param [Boolean] with_group_members If notification index will include group members
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def unopened_index(reverse = false, with_group_members = false)
        target_index = with_group_members ? unopened_only : unopened_only.group_owners_only
        reverse ? target_index.earliest_order : target_index.latest_order
      end

      # Selects unopened notification index.
      #   ActivityNotification::Notification.opened_index(limit)
      # is defined same as
      #   ActivityNotification::Notification.opened_only(limit).group_owners_only.latest_order
      # @scope class
      # @example Get unopened notificaton index of the @user with limit 10
      #   @notifications = @user.notifications.opened_index(10)
      #   @notifications = @user.notifications.opened_only(10).group_owners_only.latest_order
      # @param [Integer] limit Limit to query for opened notifications
      # @param [Boolean] reverse If notification index will be ordered as earliest first
      # @param [Boolean] with_group_members If notification index will include group members
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def opened_index(limit, reverse = false, with_group_members = false)
        target_index = with_group_members ? opened_only(limit) : opened_only(limit).group_owners_only
        reverse ? target_index.earliest_order : target_index.latest_order
      end

      # Selects filtered notifications or subscriptions by associated instance.
      # @scope class
      # @param [String] name     Association name
      # @param [Object] instance Associated instance
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def filtered_by_association(name, instance)
        instance.present? ? where("#{name}_key" => "#{instance.class.name}#{ActivityNotification.config.composite_key_delimiter}#{instance.id}") : none
      end

      # Selects filtered notifications or subscriptions by association type.
      # @scope class
      # @param [String] name     Association name
      # @param [Object] type     Association type
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def filtered_by_association_type(name, type)
        type.present? ? where("#{name}_key.begins_with" => "#{type}#{ActivityNotification.config.composite_key_delimiter}") : none
      end

      # Selects filtered notifications or subscriptions by association type and id.
      # @scope class
      # @param [String] name     Association name
      # @param [Object] type     Association type
      # @param [String] id       Association id
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def filtered_by_association_type_and_id(name, type, id)
        type.present? ? where("#{name}_key" => "#{type}#{ActivityNotification.config.composite_key_delimiter}#{id}") : none
      end

      # Selects filtered notifications or subscriptions by target instance.
      #   ActivityNotification::Notification.filtered_by_target(@user)
      # is the same as
      #   @user.notifications
      # @scope class
      # @param [Object] target Target instance for filter
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def filtered_by_target(target)
        filtered_by_association("target", target)
      end

      # Selects filtered notifications by notifiable instance.
      # @example Get filtered unopened notificatons of the @user for @comment as notifiable
      #   @notifications = @user.notifications.unopened_only.filtered_by_instance(@comment)
      # @scope class
      # @param [Object] notifiable Notifiable instance for filter
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def filtered_by_instance(notifiable)
        filtered_by_association("notifiable", notifiable)
      end

      # Selects filtered notifications by group instance.
      # @example Get filtered unopened notificatons of the @user for @article as group
      #   @notifications = @user.notifications.unopened_only.filtered_by_group(@article)
      # @scope class
      # @param [Object] group Group instance for filter
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def filtered_by_group(group)
        filtered_by_association("group", group)
      end

      # Selects filtered notifications or subscriptions by target_type.
      # @example Get filtered unopened notificatons of User as target type
      #   @notifications = ActivityNotification.Notification.unopened_only.filtered_by_target_type('User')
      # @scope class
      # @param [String] target_type Target type for filter
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def filtered_by_target_type(target_type)
        filtered_by_association_type("target", target_type)
      end

      # Selects filtered notifications by notifiable_type.
      # @example Get filtered unopened notificatons of the @user for Comment notifiable class
      #   @notifications = @user.notifications.unopened_only.filtered_by_type('Comment')
      # @scope class
      # @param [String] notifiable_type Notifiable type for filter
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def filtered_by_type(notifiable_type)
        filtered_by_association_type("notifiable", notifiable_type)
      end

      # Selects filtered notifications or subscriptions by key.
      # @example Get filtered unopened notificatons of the @user with key 'comment.reply'
      #   @notifications = @user.notifications.unopened_only.filtered_by_key('comment.reply')
      # @scope class
      # @param [String] key Key of the notification for filter
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def filtered_by_key(key)
        where(key: key)
      end

      # Selects filtered notifications or subscriptions by notifiable_type, group or key with filter options.
      # @example Get filtered unopened notificatons of the @user for Comment notifiable class
      #   @notifications = @user.notifications.unopened_only.filtered_by_options({ filtered_by_type: 'Comment' })
      # @example Get filtered unopened notificatons of the @user for @article as group
      #   @notifications = @user.notifications.unopened_only.filtered_by_options({ filtered_by_group: @article })
      # @example Get filtered unopened notificatons of the @user for Article instance id=1 as group
      #   @notifications = @user.notifications.unopened_only.filtered_by_options({ filtered_by_group_type: 'Article', filtered_by_group_id: '1' })
      # @example Get filtered unopened notificatons of the @user with key 'comment.reply'
      #   @notifications = @user.notifications.unopened_only.filtered_by_options({ filtered_by_key: 'comment.reply' })
      # @example Get filtered unopened notificatons of the @user for Comment notifiable class with key 'comment.reply'
      #   @notifications = @user.notifications.unopened_only.filtered_by_options({ filtered_by_type: 'Comment', filtered_by_key: 'comment.reply' })
      # @example Get custom filtered notificatons of the @user
      #   @notifications = @user.notifications.unopened_only.filtered_by_options({ custom_filter: ["created_at >= ?", time.hour.ago] })
      # @scope class
      # @param [Hash] options Options for filter
      # @option options [String]     :filtered_by_type       (nil) Notifiable type for filter
      # @option options [Object]     :filtered_by_group      (nil) Group instance for filter
      # @option options [String]     :filtered_by_group_type (nil) Group type for filter, valid with :filtered_by_group_id
      # @option options [String]     :filtered_by_group_id   (nil) Group instance id for filter, valid with :filtered_by_group_type
      # @option options [String]     :filtered_by_key        (nil) Key of the notification for filter
      # @option options [Array|Hash] :custom_filter          (nil) Custom notification filter (e.g. ['created_at.gt': time.hour.ago])
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications or subscriptions
      def filtered_by_options(options = {})
        options = ActivityNotification.cast_to_indifferent_hash(options)
        filtered_notifications = self
        if options.has_key?(:filtered_by_type)
          filtered_notifications = filtered_notifications.filtered_by_type(options[:filtered_by_type])
        end
        if options.has_key?(:filtered_by_group)
          filtered_notifications = filtered_notifications.filtered_by_group(options[:filtered_by_group])
        end
        if options.has_key?(:filtered_by_group_type) && options.has_key?(:filtered_by_group_id)
          filtered_notifications = filtered_notifications.filtered_by_association_type_and_id("group", options[:filtered_by_group_type], options[:filtered_by_group_id])
        end
        if options.has_key?(:filtered_by_key)
          filtered_notifications = filtered_notifications.filtered_by_key(options[:filtered_by_key])
        end
        if options.has_key?(:custom_filter)
          filtered_notifications = filtered_notifications.where(options[:custom_filter])
        end
        filtered_notifications       
      end

      # Orders by latest (newest) first as created_at: :desc.
      # It uses sort key of Global Secondary Index in DynamoDB tables.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications or subscriptions ordered by latest first
      def latest_order
        # order(created_at: :desc)
        scan_index_forward(false)
      end

      # Orders by earliest (older) first as created_at: :asc.
      # It uses sort key of Global Secondary Index in DynamoDB tables.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications or subscriptions ordered by earliest first
      def earliest_order
        # order(created_at: :asc)
        scan_index_forward(true)
      end

      # Orders by latest (newest) first as created_at: :desc and returns as array.
      # @param [Boolean] reverse If notifications or subscriptions will be ordered as earliest first
      # @return [Array] Array of notifications or subscriptions ordered by latest first
      def latest_order!(reverse = false)
        # order(created_at: :desc)
        reverse ? earliest_order! : earliest_order!.reverse
      end

      # Orders by earliest (older) first as created_at: :asc and returns as array.
      # It does not use sort key in DynamoDB tables.
      # @return [Array] Array of notifications or subscriptions ordered by earliest first
      def earliest_order!
        # order(created_at: :asc)
        all.to_a.sort_by {|n| n.created_at }
      end

      # Orders by latest (newest) first as subscribed_at: :desc.
      # @return [Array] Array of subscriptions ordered by latest subscribed_at first
      def latest_subscribed_order
        # order(subscribed_at: :desc)
        earliest_subscribed_order.reverse
      end

      # Orders by earliest (older) first as subscribed_at: :asc.
      # @return [Array] Array of subscriptions ordered by earliest subscribed_at first
      def earliest_subscribed_order
        # order(subscribed_at: :asc)
        all.to_a.sort_by {|n| n.subscribed_at }
      end

      # Orders by key name as key: :asc.
      # @return [Array] Array of subscriptions ordered by key name
      def key_order
        # order(key: :asc)
        all.to_a.sort_by {|n| n.key }
      end

      # Selects group owner notifications only.
      # @scope class
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def group_owners_only
        where('group_owner_id.null': true)
      end

      # Selects group member notifications only.
      # @scope class
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def group_members_only
        where('group_owner_id.not_null': true)
      end

      # Selects unopened notifications only.
      # @scope class
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def unopened_only
        where('opened_at.null': true)
      end

      # Selects opened notifications only without limit.
      # Be careful to get too many records with this method.
      # @scope class
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def opened_only!
        where('opened_at.not_null': true)
      end

      # Selects opened notifications only with limit.
      # @scope class
      # @param [Integer] limit Limit to query for opened notifications
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def opened_only(limit)
        limit == 0 ? none : opened_only!.limit(limit)
      end

      # Selects group member notifications in unopened_index.
      # @scope class
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def unopened_index_group_members_only
        where('group_owner_id.in': unopened_index.map(&:id))
      end

      # Selects group member notifications in opened_index.
      # @scope class
      # @param [Integer] limit Limit to query for opened notifications
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def opened_index_group_members_only
        where('group_owner_id.in': opened_index(limit).map(&:id))
      end

      # Selects notifications within expiration.
      # @scope class
      # @param [ActiveSupport::Duration] expiry_delay Expiry period of notifications
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def within_expiration_only(expiry_delay)
        where('created_at.gt': expiry_delay.ago)
      end

      # Selects group member notifications with specified group owner ids.
      # @scope class
      # @param [Array<String>] owner_ids Array of group owner ids
      # @return [Dynamoid::Criteria::Chain] Database query of filtered notifications
      def group_members_of_owner_ids_only(owner_ids)
        owner_ids.present? ? where('group_owner_id.in': owner_ids) : none
      end

      # Includes target instance with query for notifications or subscriptions.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications with target
      def with_target
        self
      end

      # Includes notifiable instance with query for notifications.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications with notifiable
      def with_notifiable
        self
      end

      # Includes group instance with query for notifications.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications with group
      def with_group
        self
      end

      # Includes group owner instances with query for notifications.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications with group owner
      def with_group_owner
        self
      end

      # Includes group member instances with query for notifications.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications with group members
      def with_group_members
        self
      end

      # Includes notifier instance with query for notifications.
      # @return [Dynamoid::Criteria::Chain] Database query of notifications with notifier
      def with_notifier
        self
      end

      # Dummy reload method for test of notifications or subscriptions.
      def reload
        self
      end

      # Returns latest notification instance.
      # @return [Notification] Latest notification instance
      def latest
        latest_order.first
      end

      # Returns earliest notification instance.
      # @return [Notification] Earliest notification instance
      def earliest
        earliest_order.first
      end

      # Selects unique keys from query for notifications or subscriptions.
      # @return [Array<String>] Array of notification unique keys
      def uniq_keys
        all.to_a.collect {|n| n.key }.uniq
      end
    end
  end
end

require_relative 'dynamoid/notification.rb'
require_relative 'dynamoid/subscription.rb'
