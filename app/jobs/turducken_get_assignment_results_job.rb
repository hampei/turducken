class TurduckenGetAssignmentResultsJob
  @queue = :mturk

  def self.perform(hit_id, assignment_id)
    job = Turducken::Job.where(:hit_id => hit_id).first
    hit = RTurk::Hit.new(hit_id)
    assignments = hit.assignments
    
    assignments.each do |ass|
      #find this assignment
      if ass.id == assignment_id
        Turducken::Assignment.create_from_mturk(job, ass)
      end
    end
    
  end

end

