class CreateStepInvocations < ActiveRecord::Migration[7.1]
  def change
    create_table :step_invocations do |t|
      t.bigint :run_id
      t.string :step

      t.timestamps
    end
  end
end
