# frozen_string_literal: true

require "spec_helper"
require "googleauth"

# rubocop:disable Style/ClassVars
class E2EThingExtendingJob
  extend Resque::Kubernetes::Job

  @@namespace = nil

  # rubocop:disable Metrics/MethodLength
  def self.job_manifest
    {
        "metadata" => {
            "name"      => "e2ething",
            "namespace" => @@namespace,
            "labels"    => {"e2e-tests" => "E2EThingExtendingJob"}
        },
        "spec"     => {
            "template" => {
                "spec" => {
                    "containers" => [
                        {
                            "name"    => "e2e-test",
                            "image"   => "ubuntu",
                            "command" => ["pwd"]
                        }
                    ]
                }
            }
        }
    }
  end
  # rubocop:enable Metrics/MethodLength
end

def namespace_generator(name)
  Kubeclient::Resource.new(metadata: {name: name})
end

RSpec.describe "Create a job", type: "e2e" do
  after do
    manager = Resque::Kubernetes::JobsManager.new(E2EThingExtendingJob)
    resque_jobs = manager.send(:jobs_client).get_jobs(
      label_selector: "resque-kubernetes=job,e2e-tests=E2EThingExtendingJob"
    )
    resque_jobs.each do |job|

      manager.send(:jobs_client).delete_job(job.metadata.name, job.metadata.namespace)
    rescue KubeException => e
      raise unless e.error_code == 404

    end

  end

  it "launches a job in the cluster which completes when done" do
    manager = Resque::Kubernetes::JobsManager.new(E2EThingExtendingJob)
    # Don't run #before_enqueue_kubernetes_job because we don't want this test reaping finished jobs from elsewhere
    manager.apply_kubernetes_job

    resque_jobs = manager.send(:jobs_client).get_jobs(
      label_selector: "resque-kubernetes=job,e2e-tests=E2EThingExtendingJob"
    )
    expect(resque_jobs.count).to eq 1
    expect(resque_jobs.first.spec.completions).to eq 1
  end

  context "when Resque::Kubernetes.restrict_to_default_namespace is enabled" do
    let(:client) do
      context = Resque::Kubernetes::ContextFactory.context
      Kubeclient::Client.new(context.endpoint, context.version, **context.options)
    end

    after do
      client.delete_namespace("resque-kubernetes-test-1", nil, delete_options: {})
      client.delete_namespace("resque-kubernetes-test-2", nil, delete_options: {})
    end

    it "should only list jobs within the default namespace" do
      client.create_namespace namespace_generator("resque-kubernetes-test-1")
      client.create_namespace namespace_generator("resque-kubernetes-test-2")

      E2EThingExtendingJob.class_variable_set(:@@namespace, "resque-kubernetes-test-1")
      manager = Resque::Kubernetes::JobsManager.new(E2EThingExtendingJob)
      manager.apply_kubernetes_job

      E2EThingExtendingJob.class_variable_set(:@@namespace, "resque-kubernetes-test-2")
      manager = Resque::Kubernetes::JobsManager.new(E2EThingExtendingJob)
      manager.apply_kubernetes_job

      E2EThingExtendingJob.class_variable_set(:@@namespace, nil)
      manager = Resque::Kubernetes::JobsManager.new(E2EThingExtendingJob)
      manager.apply_kubernetes_job

      count = 0
      while count != 60
        finished_jobs = manager.send(:finished_jobs)
        break if finished_jobs.count == 3

        count += 1
        sleep 1
      end

      expect(count).to_not eq 60 # timeout occurred for all jobs to complete

      allow(Resque::Kubernetes).to receive(:restrict_to_default_namespace).and_return(true)
      expect(manager.send(:finished_jobs).count).to eq 1
      expect(manager.send(:finished_jobs).first.spec.completions).to eq 1
      expect(manager.send(:finished_jobs).first.metadata.namespace)
        .to eq manager.instance_variable_get(:@default_namespace)
    end
  end
end
# rubocop:enable Style/ClassVars
