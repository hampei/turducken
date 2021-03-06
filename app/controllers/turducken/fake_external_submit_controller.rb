module Turducken
  class FakeExternalSubmitController < ActionController::Base
    before_filter :check_settings!
    
    def create
      job = Turducken::Job.where(:hit_id => params['hitId']).first
      worker = Turducken.worker_model.find_or_create_by(:turk_id => 'fake')
      assignment = Assignment.find_or_initialize_by(:assignment_id => params['assignmentId'])
      assignment.worker = worker
      assignment.answers = params
      assignment.set_current_state(assignment.machine.states[:submitted])
      assignment.save
      # puts "fake_submit: #{job.inspect} - #{assignment.inspect}"
      Turducken::Assignment.handle_assignment_event(job, assignment)
      render :text => 'done'
    end
    
    def check_settings!
      raise 'Turducken.fake_external_submit needs to be true for this controller to be used' unless Turducken.fake_external_submit
    end
  end
end
