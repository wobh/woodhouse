#
#  All worker classes must inherit from this class, and be saved in app/workers. 
# 
#  The Worker lifecycle: 
#    The Worker is loaded once, at which point the instance method 'create' is called. 
#
#  Invoking Workers: 
#    Calling async_my_method on the worker class will trigger background work.
#    This means that the loaded Worker instance will receive a call to the method
#    my_method(:uid => "thisjobsuid2348732947923"). 
#
#    The Worker method must have a single hash argument. Note that the job :uid will
#    be merged into the hash. 
#
module Ganymede
  class Base
    cattr_accessor :logger
    @@logger ||= ::RAILS_DEFAULT_LOGGER
    
    def self.inherited(subclass)
      Ganymede::Discovery.discovered << subclass
    end
    
    def initialize
      super
      
      create
    end

    # Put worker initialization code in here. This is good for restarting jobs that
    # were interrupted.
    def create
    end
    
    # takes care of suppressing remote errors but raising Ganymede::GanymedeNotFoundError
    # where appropriate. swallow workling exceptions so that everything behaves like remote code.
    # otherwise StarlingRunner and SpawnRunner would behave too differently to NotRemoteRunner.
    def dispatch_to_worker_method(method, options)
      begin
        Ganymede.log_job options[:uid], "received"
        ret = self.send(method, options)
        Ganymede.log_job options[:uid], "completed"
        ret
      rescue => e
        Ganymede.log_job options[:uid], "raised exception", :error => { :type => e.class.name, :message => e.message, :backtrace => e.backtrace }, :_exception => e
        raise e if e.kind_of?(Ganymede::GanymedeError)
        raise e if e.kind_of?(ActiveRecord::StatementInvalid) and e.message =~ /memory/i # generally indicates a DB error, or a JDBC OOM condition. Want to bomb out the worker in this case.
        if defined? Java::JavaLang::OutOfMemoryError
          raise e if e.kind_of?(Java::JavaLang::OutOfMemoryError)
        end
        if defined? NativeException
          raise e if e.kind_of?(NativeException)
        end

        logger.error "WORKLING ERROR: runner could not invoke #{ self.class }:#{ method } with #{ options.inspect }. error was: #{ e.inspect }\n #{ e.backtrace.join("\n") }"
        
        # reraise after logging. the exception really can't go anywhere in many cases. (spawn traps the exception)
        #raise e if Ganymede.raise_exceptions?
      end
    end    
  
    # thanks to blaine cook for this suggestion.
    def self.method_missing(method, *args, &block)
      if method.to_s =~ /^asynch?_(.*)/
        Ganymede::Remote.run(self.to_s.dasherize, $1, *args)
      else
        super
      end
    end
  end
end
