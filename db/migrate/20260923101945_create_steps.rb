class CreateSteps < ActiveRecord::Migration[7.1]
  def change
    create_table :steps do |t|
      t.references :run, null: false, foreign_key: true
      t.integer :position
      t.string :status
      t.jsonb :output

      t.timestamps
    end
  end
end
