require "spec_helper"
require "hamster/sorted_set"

describe Hamster::SortedSet do
  describe "#drop" do
    [
      [[], 10, []],
      [["A"], 10, []],
      [%w[A B C], 0, %w[A B C]],
      [%w[A B C], 2, ["C"]],
    ].each do |values, number, expected|

      describe "#{number} from #{values.inspect}" do
        before do
          @original = Hamster.sorted_set(*values)
          @result = @original.drop(number)
        end

        it "preserves the original" do
          @original.should eql(Hamster.sorted_set(*values))
        end

        it "returns #{expected.inspect}" do
          @result.should eql(Hamster.sorted_set(*expected))
        end
      end
    end
  end
end