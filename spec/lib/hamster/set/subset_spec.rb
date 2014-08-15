require "spec_helper"
require "hamster/set"

describe Hamster::Set do
  [:subset?, :<=].each do |method|
    describe "##{method}" do
      [
        [[], [], true],
        [["A"], [], false],
        [[], ["A"], true],
        [["A"], ["A"], true],
        [%w[A B C], ["B"], false],
        [["B"], %w[A B C], true],
        [%w[A B C], %w[A C], false],
        [%w[A C], %w[A B C], true],
        [%w[A B C], %w[A B C], true],
        [%w[A B C], %w[A B C D], true],
        [%w[A B C D], %w[A B C], false],
      ].each do |a, b, expected|
        describe "for #{a.inspect} and #{b.inspect}" do
          it "returns #{expected}"  do
            Hamster.set(*a).send(method, Hamster.set(*b)).should == expected
          end
        end
      end
    end
  end

  [:proper_subset?, :<].each do |method|
    describe "##{method}" do
      [
        [[], [], false],
        [["A"], [], false],
        [[], ["A"], true],
        [["A"], ["A"], false],
        [%w[A B C], ["B"], false],
        [["B"], %w[A B C], true],
        [%w[A B C], %w[A C], false],
        [%w[A C], %w[A B C], true],
        [%w[A B C], %w[A B C], false],
        [%w[A B C], %w[A B C D], true],
        [%w[A B C D], %w[A B C], false],
      ].each do |a, b, expected|
        describe "for #{a.inspect} and #{b.inspect}" do
          it "returns #{expected}"  do
            Hamster.set(*a).send(method, Hamster.set(*b)).should == expected
          end
        end
      end
    end
  end
end