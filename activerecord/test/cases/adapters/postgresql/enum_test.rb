# frozen_string_literal: true

require "cases/helper"
require "support/connection_helper"
require "support/schema_dumping_helper"

class PostgresqlEnumTest < ActiveRecord::PostgreSQLTestCase
  include ConnectionHelper
  include SchemaDumpingHelper

  class PostgresqlEnum < ActiveRecord::Base
    self.table_name = "postgresql_enums"

    enum current_mood: {
      sad: "sad",
      okay: "ok", # different spelling
      happy: "happy",
      aliased_field: "happy"
    }, _prefix: true
  end

  def setup
    @connection = ActiveRecord::Base.connection
    @connection.transaction do
      @connection.create_enum("mood", ["sad", "ok", "happy"])
      @connection.create_table("postgresql_enums") do |t|
        t.column :current_mood, :mood
      end
    end
  end

  teardown do
    reset_connection
    @connection.drop_table "postgresql_enums", if_exists: true
    @connection.drop_enum "mood", if_exists: true
    reset_connection
  end

  def test_column
    column = PostgresqlEnum.columns_hash["current_mood"]
    assert_equal :enum, column.type
    assert_equal "mood", column.sql_type
    assert_not_predicate column, :array?

    type = PostgresqlEnum.type_for_attribute("current_mood")
    assert_not_predicate type, :binary?
  end

  def test_enum_defaults
    @connection.add_column "postgresql_enums", "good_mood", :mood, default: "happy"
    PostgresqlEnum.reset_column_information

    assert_equal "happy", PostgresqlEnum.column_defaults["good_mood"]
    assert_equal "happy", PostgresqlEnum.new.good_mood
  ensure
    PostgresqlEnum.reset_column_information
  end

  def test_enum_mapping
    @connection.execute "INSERT INTO postgresql_enums VALUES (1, 'sad');"
    enum = PostgresqlEnum.first
    assert_equal "sad", enum.current_mood

    enum.current_mood = "happy"
    enum.save!

    assert_equal "happy", enum.reload.current_mood
  end

  def test_invalid_enum_update
    @connection.execute "INSERT INTO postgresql_enums VALUES (1, 'sad');"
    enum = PostgresqlEnum.first

    assert_raise ArgumentError do
      enum.current_mood = "angry"
    end
  end

  def test_no_oid_warning
    @connection.execute "INSERT INTO postgresql_enums VALUES (1, 'sad');"
    stderr_output = capture(:stderr) { PostgresqlEnum.first }

    assert_predicate stderr_output, :blank?
  end

  def test_enum_type_cast
    enum = PostgresqlEnum.new
    enum.current_mood = :happy

    assert_equal "happy", enum.current_mood
  end

  def test_assigning_enum_to_nil
    model = PostgresqlEnum.new(current_mood: nil)

    assert_nil model.current_mood
    assert model.save
    assert_nil model.reload.current_mood
  end

  def test_schema_dump
    @connection.add_column "postgresql_enums", "good_mood", :mood, default: "happy", null: false

    output = dump_table_schema("postgresql_enums")

    assert output.include?("# Note that some types may not work with other database engines. Be careful if changing database."), output

    assert output.include?('create_enum "mood", ["sad", "ok", "happy"]'), output

    assert output.include?('t.enum "current_mood", enum_type: "mood"'), output
    assert output.include?('t.enum "good_mood", default: "happy", null: false, enum_type: "mood"'), output
  end

  def test_schema_load
    original, $stdout = $stdout, StringIO.new

    ActiveRecord::Schema.define do
      create_enum :color, ["blue", "green"]

      change_table :postgresql_enums do |t|
        t.enum :best_color, enum_type: "color", default: "blue", null: false
      end
    end

    assert @connection.column_exists?(:postgresql_enums, :best_color, sql_type: "color", default: "blue", null: false)
  ensure
    $stdout = original
  end

  def test_drop_enum
    @connection.create_enum :unused, []

    assert_nothing_raised do
      @connection.drop_enum "unused"
    end

    assert_nothing_raised do
      @connection.drop_enum "unused", if_exists: true
    end

    assert_raises ActiveRecord::StatementInvalid do
      @connection.drop_enum "unused"
    end
  end

  def test_works_with_activerecord_enum
    model = PostgresqlEnum.create!
    model.current_mood_okay!

    model = PostgresqlEnum.find(model.id)
    assert_equal "okay", model.current_mood

    model.current_mood = "happy"
    model.save!

    model = PostgresqlEnum.find(model.id)
    assert model.current_mood_happy?
  end

  def test_enum_type_scoped_to_schemas
    old_search_path = @connection.schema_search_path
    @connection.create_schema("test_schema")
    @connection.schema_search_path = "test_schema"
    @connection.schema_cache.clear!
    @connection.create_enum("mood_in_other_schema", ["sad", "ok", "happy"])

    assert_nothing_raised do
      @connection.create_table("postgresql_enums_in_other_schema") do |t|
        t.column :current_mood, :mood_in_other_schema, default: "happy", null: false
      end
    end

    assert_nothing_raised do
      @connection.drop_table("postgresql_enums_in_other_schema")
      @connection.drop_enum("mood_in_other_schema")
    end
  ensure
    @connection.drop_schema("test_schema")
    @connection.schema_search_path = old_search_path
    @connection.schema_cache.clear!
  end

  def test_enum_type_explicit_schema
    @connection.create_schema("test_schema")
    @connection.create_enum("test_schema.mood_in_other_schema", ["sad", "ok", "happy"])

    @connection.create_table("test_schema.postgresql_enums_in_other_schema") do |t|
      t.column :current_mood, "test_schema.mood_in_other_schema"
    end

    assert @connection.table_exists?("test_schema.postgresql_enums_in_other_schema")

    assert_nothing_raised do
      @connection.drop_table("test_schema.postgresql_enums_in_other_schema")
      @connection.drop_enum("test_schema.mood_in_other_schema")
    end
  ensure
    @connection.drop_schema("test_schema", if_exists: true)
  end
end
