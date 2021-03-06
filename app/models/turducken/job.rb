module Turducken
  class Job
    include Mongoid::Document
    include Mongoid::Timestamps
    include Stateflow
    Stateflow.persistence = :mongoid #TODO find better way of doing this. maybe gem load order?

    field :hit_title
    field :hit_description
    field :hit_question_type # this should be either 'external' or 'questionform'
    field :hit_id
    field :hit_type_id
    field :hit_url
    field :hit_reward, type: Float
    field :hit_num_assignments, type: Integer, default: 1
    field :hit_lifetime_s, type: Integer, default: 1.week
    field :hit_assignment_duration_s, type: Integer, :default => 1.hour # time user can spend on an assignment
    field :hit_question, type: String
    field :require_approved_assignments, type: Integer, :default => 0
    field :hit_keywords, type: Array
    def require_approved_assignments=(num); super(num == true ? hit_num_assignments : num); end

    field :complete, type: Boolean
    field :state

    index :hit_id
    index [[:state, Mongo::ASCENDING], [:_id, Mongo::DESCENDING]]

    scope :running,  where(:state => 'running')
    scope :finished, where(:state => 'finished')
    scope :new_jobs, where(:state => 'new')
    scope :launching, where(:state => 'launching')

    has_many :assignments, :class_name => 'Turducken::Assignment'
  #  has_many :workers, :through => :assignments

    class_attribute :attributes_defaults
    self.attributes_defaults = {}
    def self.set_defaults(attrs = {})
      self.attributes_defaults = self.attributes_defaults.merge(attrs)
    end
    def initialize(attributes = {}, options = {})
      super(self.attributes_defaults.merge(attributes), options)
    end
    
    class_attribute :qualifications
    self.qualifications = []
    def self.qualification(symbol, hash)
      self.qualifications << [symbol, hash]
    end

    after_create do
      launch!
    end

    before_destroy do
      hit = self.as_hit

      unless hit.nil?
        hit.expire! if (hit.status == "Assignable" || hit.status == 'Unassignable')
        hit.assignments.each do |assignment|
          assignment.approve! if assignment.status == 'Submitted'
        end
        hit.dispose!
      end
    end

    def self.auto_approve(y=true)
      @auto_approve = y
    end
    def self.auto_approve?
      @auto_approve
    end

    stateflow do
      state_column :state
      initial :new

      state :new

      state :launching do
        enter :do_launch
      end

      state :running
      
      state :reviewing
    
      state :finished do
        after_enter do |j|
          Resque.enqueue(TurduckenHITJob, :dispose, j.hit_id)
          Resque.enqueue(TurduckenJobJob, :on_job_finished, j.id)
        end
      end

      event :launch do
        transitions :from => :new, :to => :launching, :if => :ready_to_launch?
        transitions :from => :new, :to => :new
      end
    
      event :launched do
        transitions :from => [:new, :launching], :to => :running
      end
      
      event :reviewable do
        transitions :from => :running, :to => :reviewing
      end
      
      event :hit_extended do
        transitions :from => [:running, :reviewing], :to => :running
      end
  
      event :finish do
       transitions :from => [:running, :reviewing],  :to => :finished
      end
    end

    #
    # Either get and return the HIT, or nil
    #
    def as_hit
      begin
        RTurk::Hit.find(hit_id)
      rescue RTurk::InvalidRequest => e
        nil
      end
    end

    class_attribute :turducken_assignment_callbacks
    self.turducken_assignment_callbacks = {}
    class << self
      [:submitted, :approved, :rejected].each do |event|
        define_method "on_assignment_#{event}" do |&block|
          self.turducken_assignment_callbacks = self.turducken_assignment_callbacks.dup
          self.turducken_assignment_callbacks[event] ||= []
          self.turducken_assignment_callbacks[event] += [block]
        end
      end
    end

    def turducken_assignment_event(assignment, event_type)
      cb = self.class.turducken_assignment_callbacks
      return unless cb and cb[event_type]
      self.class.turducken_assignment_callbacks[event_type].each do |block|
        instance_exec(assignment, &block)
      end
    end
    
    def on_hit_finished
    end

    # checks how the job is progressing. 
    # if it need more assignments to fullfil the approved_assignments minimum, requests them.
    # if job is finished, finishes the job.
    def check_progress!
      return if finished?
      raise "State error (#{state}) in check_progress!" if new? or launching?
      if more_assignments_needed?
        extend_hit!
      elsif all_assignments_handled? && enough_assignments_approved?
        finish!
      end
    end

    # options:
    #   assignments: increment nr of assignments. defaults to more_assignments_needed
    #   seconds: increase time of the job (from now if job already expired)
    def extend_hit!(options={})
      options[:assignments] ||= more_assignments_needed
      RTurk.ExtendHIT(options.merge!(:hit_id => hit_id))
      self[:hit_num_assignments] += options[:assignments]
      hit_extended!
    end

  private
    
    def enough_assignments_approved?
      require_approved_assignments == 0 ? true :
        assignments.approved.count >= require_approved_assignments
    end
    
    def all_assignments_submitted?
      assignments.count >= hit_num_assignments
    end

    def all_assignments_handled?
      assignments.approved.count + assignments.rejected.count >= hit_num_assignments
    end

    def more_assignments_needed?; more_assignments_needed > 0; end
    def more_assignments_needed
      require_approved_assignments == 0 ? 0 :
        [0, assignments.rejected.count - (hit_num_assignments - require_approved_assignments)].max
    end

    def ready_to_launch?
      # TODO: validation that the job is in a launchable state
      # need a url to question, amount of reward, auto-accept?, etc.
      true
    end
  
    def do_launch
      Resque.enqueue(TurduckenLaunchJob, self.id)
    end

  end
end
