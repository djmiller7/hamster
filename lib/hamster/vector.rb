require "forwardable"
require "hamster/immutable"
require "hamster/enumerable"
require "hamster/hash"

module Hamster
  def self.vector(*items)
    items.empty? ? EmptyVector : Vector.new(items.freeze)
  end

  # A `Vector` is an ordered, integer-indexed collection of objects. Like `Array`,
  # `Vector` indexing starts at 0. Also like `Array`, negative indexes count back
  # from the end of the `Vector`.
  #
  # `Vector`'s interface is modeled after that of `Array`, minus all the methods
  # which do destructive updates. Some methods which modify `Array`s destructively
  # (like {#insert} or {#delete_at}) are included, but they return new `Vectors`
  # and leave the existing one unchanged.
  #
  # = Creating New Vectors
  #
  #     Hamster.vector('a', 'b', 'c')
  #     Hamster::Vector.new([:first, :second, :third])
  #     Hamster::Vector[1, 2, 3, 4, 5]
  #
  # = Retrieving Items from Vectors
  #
  #     require 'hamster/vector'
  #     vector = Hamster.vector(1, 2, 3, 4, 5)
  #     vector[0]      # => 1
  #     vector[-1]     # => 5
  #     vector[0,3]    # => Hamster::Vector[1, 2, 3]
  #     vector[1..-1]  # => Hamster::Vector[2, 3, 4, 5]
  #     vector.first   # => 1
  #     vector.last    # => 5
  #
  # = Creating Modified Vectors
  #
  #     vector.add(6)            # => Hamster::Vector[1, 2, 3, 4, 5, 6]
  #     vector.insert(1, :a, :b) # => Hamster::Vector[1, :a, :b, 2, 3, 4, 5]
  #     vector.delete_at(2)      # => Hamster::Vector[1, 2, 4, 5]
  #     vector + [6, 7]          # => Hamster::Vector[1, 2, 3, 4, 5, 6, 7]
  #
  # Other `Array`-like methods like {#select}, {#map}, {#shuffle}, {#uniq}, {#reverse},
  # {#rotate}, {#flatten}, {#sort}, {#sort_by}, {#take}, {#drop}, {#take_while},
  # {#drop_while}, {#fill}, {#product}, and {#transpose} are also supported.
  #
  class Vector
    extend Forwardable
    include Immutable
    include Enumerable

    # @private
    BLOCK_SIZE = 32
    # @private
    INDEX_MASK = BLOCK_SIZE - 1
    # @private
    BITS_PER_LEVEL = 5

    # Return the number of items in this `Vector`
    # @return [Integer]
    attr_reader :size
    def_delegator :self, :size, :length

    class << self
      # Create a new `Vector` populated with the given items.
      # @return [Vector]
      def [](*items)
        new(items.freeze)
      end

      # Return an empty `Vector`. If used on a subclass, returns an empty instance
      # of that class.
      #
      # @return [Vector]
      def empty
        @empty ||= self.new
      end

      # "Raw" allocation of a new `Vector`. Used internally to create a new
      # instance quickly after building a modified trie.
      #
      # @return [Vector]
      # @private
      def alloc(root, size, levels)
        obj = allocate
        obj.instance_variable_set(:@root, root)
        obj.instance_variable_set(:@size, size)
        obj.instance_variable_set(:@levels, levels)
        obj
      end
    end

    def initialize(items=[].freeze)
      items = items.to_a
      if items.size <= 32
        items = items.dup.freeze if !items.frozen?
        @root, @size, @levels = items, items.size, 0
      else
        root, size, levels = items, items.size, 0
        while root.size > 32
          root = root.each_slice(32).to_a
          levels += 1
        end
        @root, @size, @levels = root.freeze, size, levels
      end
    end

    # Return `true` if this `Vector` contains no items.
    #
    # @return [Boolean]
    def empty?
      @size == 0
    end
    def_delegator :self, :empty?, :null?

    # Return the first item in the `Vector`. If the vector is empty, return `nil`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"].first  # => "A"
    #
    # @return [Object]
    def first
      get(0)
    end
    def_delegator :self, :first, :head

    # Return the last item in the `Vector`. If the vector is empty, return `nil`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"].last  # => "C"
    #
    # @return [Object]
    def last
      get(-1)
    end

    # Return a new `Vector` with `item` added after the last occupied position.
    #
    # @example
    #   Hamster::Vector[1, 2].add(99)  # => Hamster::Vector[1, 2, 99]
    #
    # @param item [Object] The object to insert at the end of the vector
    # @return [Vector]
    def add(item)
      update_root(@size, item)
    end
    def_delegator :self, :add, :<<
    def_delegator :self, :add, :conj
    def_delegator :self, :add, :conjoin
    def_delegator :self, :add, :push

    # Return a new `Vector` with the item at `index` replaced by `item`. If the
    # `item` argument is missing, but an optional code block is provided, it will
    # be passed the existing item and what the block returns will replace it.
    #
    # @example
    #   Hamster::Vector[1, 2, 3, 4].set(2, 99)
    #   # => Hamster::Vector[1, 2, 99, 4]
    #   Hamster::Vector[1, 2, 3, 4].set(2) { |v| v * 10 }
    #   # => Hamster::Vector[1, 2, 30, 4]
    #
    # @param index [Integer] The index to update
    # @param item [Object] The object to insert into that position
    # @return [Vector]
    def set(index, item = yield(get(index)))
      raise IndexError if @size == 0
      index += @size if index < 0
      raise IndexError if index > @size || index < 0
      update_root(index, item)
    end

    # Return a new `Vector` with a deeply nested value modified to the result
    # of the given code block.  When travesing the nested `Vector`s and
    # `Hash`s, non-existing keys are created with value of empty `Hash`s.
    #
    # The code block receives the existing value of the deeply nested key (or
    # `nil` if it doesn't exist). This is useful for "transforming" the value
    # associated with a certain key.
    #
    # Note that the original `Vector` and sub-`Vector`s and sub-`Hash`s are
    # left unmodified; new data structure copies are created along the path
    # wherever needed.
    #
    # @example
    #   v = Hamster::Vector[123, 456, 789, Hamster::Hash["a" => Hamster::Vector[5, 6, 7]]]
    #   v.update_in(3, "a", 1) { |value| value + 9 }
    #   # => Hamster::Vector[123, 456, 789, Hamster::Hash["a" => Hamster::Vector[5, 15, 7]]]
    #
    # @param key_path [Object(s)] List of keys which form the path to the key to be modified
    # @yield [value] The previously stored value
    # @yieldreturn [Object] The new value to store
    # @return [Hash]
    def update_in(*key_path, &block)
      if key_path.empty?
        raise ArgumentError, "must have at least one key in path"
      end
      key = key_path[0]
      if key_path.size == 1
        new_value = block.call(get(key))
      else
        value = fetch(key, EmptyHash)
        new_value = value.update_in(*key_path[1..-1], &block)
      end
      set(key, new_value)
    end

    # Retrieve the item at `index`. If there is none (either the provided index
    # is too high or too low), return `nil`.
    #
    # @example
    #   v = Hamster::Vector["A", "B", "C", "D"]
    #   v.get(2)   # => "C"
    #   v.get(-1)  # => "D"
    #   v.get(4)   # => nil
    #
    # @param index [Integer] The index to retrieve
    # @return [Object]
    def get(index)
      return nil if @size == 0
      index += @size if index < 0
      return nil if index >= @size || index < 0
      leaf_node_for(@root, @levels * BITS_PER_LEVEL, index)[index & INDEX_MASK]
    end
    def_delegator :self, :get, :at

    # Retrieve the value at `index`, or use the provided default value or block,
    # or otherwise raise an `IndexError`.
    #
    # @overload fetch(index)
    #   Retrieve the value at the given index, or raise an `IndexError` if it is
    #   not found.
    #   @param index [Integer] The index to look up
    # @overload fetch(index) { |index| ... }
    #   Retrieve the value at the given index, or call the optional
    #   code block (with the non-existent index) and get its return value.
    #   @yield [index] The index which does not exist
    #   @yieldreturn [Object] Object to return instead
    #   @param index [Integer] The index to look up
    # @overload fetch(index, default)
    #   Retrieve the value at the given index, or else return the provided
    #   `default` value.
    #   @param index [Integer] The index to look up
    #   @param default [Object] Object to return if the key is not found
    #
    # @example
    #   v = Hamster::Vector["A", "B", "C", "D"]
    #   v.fetch(2)       # => "C"
    #   v.fetch(-1)      # => "D"
    #   v.fetch(4)       # => IndexError: index 4 outside of vector bounds
    #   # With default value:
    #   v.fetch(2, "Z")  # => "C"
    #   v.fetch(4, "Z")  # => "Z"
    #   # With block:
    #   v.fetch(2) { |i| i * i }   # => "C"
    #   v.fetch(4) { |i| i * i }   # => 16
    #
    # @return [Object]
    def fetch(index, default = (missing_default = true))
      if index >= -@size && index < @size
        get(index)
      elsif block_given?
        yield(index)
      elsif !missing_default
        default
      else
        raise IndexError, "index #{index} outside of vector bounds"
      end
    end

    # Element reference. Return the item at a specific index, or a specified,
    # contiguous range of items (as a new `Vector`).
    #
    # @overload vector[index]
    #   Return the item at `index`.
    #   @param index [Integer] The index to retrieve.
    # @overload vector[start, length]
    #   Return a subvector starting at index `start` and continuing for `length` elements.
    #   @param start [Integer] The index to start retrieving items from.
    #   @param length [Integer] The number of items to retrieve.
    # @overload vector[range]
    #   Return a subvector specified by the given `range` of indices.
    #   @param range [Range] The range of indices to retrieve.
    #
    # @example
    #   v = Hamster::Vector["A", "B", "C", "D", "E", "F"]
    #   v[2]     # => "C"
    #   v[-1]    # => "D"
    #   v[6]     # => nil
    #   v[2, 2]  # => Hamster::Vector["C", "D"]
    #   v[2..3]  # => Hamster::Vector["C", "D"]
    #
    # @return [Object]
    def [](arg, length = (missing_length = true))
      if missing_length
        if arg.is_a?(Range)
          from, to = arg.begin, arg.end
          from += @size if from < 0
          to   += @size if to < 0
          to   += 1     if !arg.exclude_end?
          length = to - from
          length = 0 if length < 0
          subsequence(from, length)
        else
          get(arg)
        end
      else
        arg += @size if arg < 0
        subsequence(arg, length)
      end
    end
    def_delegator :self, :[], :slice

    # Return a new `Vector` with the given values inserted before the element at `index`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C", "D"].insert(2, "X", "Y", "Z")
    #   # => Hamster::Vector["A", "B", "X", "Y", "Z", "C", "D"]
    #
    # @param index [Integer] The index where the new items should go
    # @param items [Array] The items to add
    # @return [Vector]
    def insert(index, *items)
      raise IndexError if index < -@size
      index += @size if index < 0

      if index < @size
        suffix = flatten_suffix(@root, @levels * BITS_PER_LEVEL, index, [])
        suffix.unshift(*items)
      elsif index == @size
        suffix = items
      else
        suffix = Array.new(index - @size, nil).concat(items)
        index = @size
      end

      replace_suffix(index, suffix)
    end

    # Return a new `Vector` with the element at `index` removed. If the given `index`
    # does not exist, return `self`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C", "D"].delete_at(2)
    #   # => Hamster::Vector["A", "B", "D"]
    #
    # @param index [Integer] The index to remove
    # @return [Vector]
    def delete_at(index)
      return self if index >= @size || index < -@size
      index += @size if index < 0

      suffix = flatten_suffix(@root, @levels * BITS_PER_LEVEL, index, [])
      replace_suffix(index, suffix.tap { |a| a.shift })
    end

    # Return a new `Vector` with the last element removed. If empty, just return `self`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"].pop  # => Hamster::Vector["A", "B"]
    #
    # @return [Vector]
    def pop
      return self if @size == 0
      replace_suffix(@size-1, [])
    end

    # Return a new `Vector` with `obj` inserted before the first element, moving
    # the other elements upwards.
    #
    # @example
    #   Hamster::Vector["A", "B"].unshift("Z")  # => Hamster::Vector["Z", "A", "B"]
    #
    # @param obj [Object] The value to prepend
    # @return [Vector]
    def unshift(obj)
      insert(0, obj)
    end

    # Return a new `Vector` with the first element removed. If empty, just return `self`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"].shift  # => Hamster::Vector["B", "C"]
    #
    # @return [Vector]
    def shift
      delete_at(0)
    end

    # Call the given block once for each item in the vector, passing each
    # item from first to last successively to the block.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"].each { |e| puts "Element: #{e}" }
    #
    #   Element: A
    #   Element: B
    #   Element: C
    #   # => Hamster::Vector["A", "B", "C"]
    #
    # @return [self]
    def each(&block)
      return to_enum unless block_given?
      traverse_depth_first(@root, @levels, &block)
      self
    end

    # Call the given block once for each item in the vector, passing each
    # item starting from the last, and counting back to the first, successively to
    # the block.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"].reverse_each { |e| puts "Element: #{e}" }
    #
    #   Element: C
    #   Element: B
    #   Element: A
    #
    # @return [self]
    def reverse_each(&block)
      return enum_for(:reverse_each) unless block_given?
      reverse_traverse_depth_first(@root, @levels, &block)
      self
    end

    # Return a new `Vector` containing all elements for which the given block returns
    # true.
    #
    # @example
    #   Hamster::Vector["Bird", "Cow", "Elephant"].filter { |e| e.size >= 4 }
    #   # => Hamster::Vector["Bird", "Elephant"]
    #
    # @return [Vector]
    def filter
      return enum_for(:filter) unless block_given?
      reduce(self.class.empty) { |vector, item| yield(item) ? vector.add(item) : vector }
    end

    # Return a new `Vector` with all items which are equal to `obj` removed.
    # `#==` is used for checking equality.
    #
    # @example
    #   Hamster::Vector["C", "B", "A", "B"].delete("B")  # => Hamster::Vector["C", "A"]
    #
    # @param obj [Object] The object to remove (every occurrence)
    # @return [Vector]
    def delete(obj)
      filter { |item| item != obj }
    end

    # Invoke the given block once for each item in the vector, and return a new
    # `Vector` containing the values returned by the block.
    #
    # @example
    #   Hamster::Vector[3, 2, 1].map { |e| e * e }  # => Hamster::Vector[9, 4, 1]
    #
    # @return [Vector]
    def map
      return enum_for(:map) if not block_given?
      return self if empty?
      self.class.new(super)
    end
    def_delegator :self, :map, :collect

    # Return a new `Vector` with the same elements as this one, but randomly permuted.
    #
    # @example
    #   Hamster::Vector[1, 2, 3, 4].shuffle  # => Hamster::Vector[4, 1, 3, 2]
    #
    # @return [Vector]
    def shuffle
      self.class.new(((array = to_a).frozen? ? array.shuffle : array.shuffle!).freeze)
    end

    # Return a new `Vector` with no duplicate elements, as determined by `#hash` and
    # `#eql?`. For each group of equivalent elements, only the first will be retained.
    #
    # @example
    #   Hamster::Vector["A", "B", "C", "B"].uniq  # => Hamster::Vector["A", "B", "C"]
    #
    # @return [Vector]
    def uniq
      self.class.new(((array = to_a).frozen? ? array.uniq : array.uniq!).freeze)
    end

    # Return a new `Vector` with the same elements as this one, but in reverse order.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"].reverse  # => Hamster::Vector["C", "B", "A"]
    #
    # @return [Vector]
    def reverse
      self.class.new(((array = to_a).frozen? ? array.reverse : array.reverse!).freeze)
    end

    # Return a new `Vector` with the same elements, but rotated so that the one at
    # index `count` is the first element of the new vector. If `count` is positive,
    # the elements will be shifted left, and those shifted past the lowest position
    # will be moved to the end. If `count` is negative, the elements will be shifted
    # right, and those shifted past the last position will be moved to the beginning.
    #
    # @example
    #   v = Hamster::Vector["A", "B", "C", "D", "E", "F"]
    #   v.rotate(2)   # => Hamster::Vector["C", "D", "E", "F", "A", "B"]
    #   v.rotate(-1)  # => Hamster::Vector["F", "A", "B", "C", "D", "E"]
    #
    # @param count [Integer] The number of positions to shift items by
    # @return [Vector]
    def rotate(count = 1)
      return self if (count % @size) == 0
      self.class.new(((array = to_a).frozen? ? array.rotate(count) : array.rotate!(count)).freeze)
    end

    # Return a new `Vector` with all nested vectors and arrays recursively "flattened
    # out", that is, their elements inserted into the new `Vector` in the place where
    # the nested array/vector originally was. If an optional `level` argument is
    # provided, the flattening will only be done recursively that number of times.
    # A `level` of 0 means not to flatten at all, 1 means to only flatten nested
    # arrays/vectors which are directly contained within this `Vector`.
    #
    # @example
    #   v = Hamster::Vector["A", Hamster::Vector["B", "C", Hamster::Vector["D"]]]
    #   v.flatten(1)
    #   # => Hamster::Vector["A", "B", "C", Hamster::Vector["D"]]
    #   v.flatten
    #   # => Hamster::Vector["A", "B", "C", "D"]
    #
    # @param level [Integer] The depth to which flattening should be applied
    # @return [Vector]
    def flatten(level = -1)
      return self if level == 0
      self.class.new(((array = to_a).frozen? ? array.flatten(level) : array.flatten!(level)).freeze)
    end

    # Return a new `Vector` built by concatenating this one with `other`. `other`
    # can be any object which is convertible to an `Array` using `#to_a`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C"] + ["D", "E"]
    #   # => Hamster::Vector["A", "B", "C", "D", "E"]
    #
    # @param other [Enumerable] The collection to concatenate onto this vector
    # @return [Vector]
    def +(other)
      other = other.to_a
      other = other.dup if other.frozen?
      replace_suffix(@size, other)
    end
    def_delegator :self, :+, :concat

    # `others` should be arrays and/or vectors. The corresponding elements from this
    # `Vector` and each of `others` (that is, the elements with the same indices)
    # will be gathered into arrays.
    #
    # If an optional block is provided, each such array will be passed successively
    # to the block. Otherwise, a new `Vector` of all those arrays will be returned.
    #
    # @example
    #   v1 = Hamster::Vector["A", "B", "C"]
    #   v2 = Hamster::Vector[1, 2, 3]
    #   v1.zip(v2)
    #   # => Hamster::Vector[["A", 1], ["B", 2], ["C", 3]]
    #
    # @param others [Array] The arrays/vectors to zip together with this one
    # @return [Vector, nil]
    def zip(*others)
      if block_given?
        super
      else
        self.class.new(super)
      end
    end

    # Return a new `Vector` with the same items, but sorted. The sort order will
    # be determined by comparing items using `#<=>`, or if an optional code block
    # is provided, by using it as a comparator. The block should accept 2 parameters,
    # and should return 0, 1, or -1 if the first parameter is equal to, greater than,
    # or less than the second parameter (respectively).
    #
    # @example
    #   Hamster::Vector["Elephant", "Dog", "Lion"].sort
    #   # => Hamster::Vector["Dog", "Elephant", "Lion"]
    #   Hamster::Vector["Elephant", "Dog", "Lion"].sort { |a,b| a.size <=> b.size }
    #   # => Hamster::Vector["Dog", "Lion", "Elephant"]
    #
    # @return [Vector]
    def sort
      self.class.new(super)
    end

    # Return a new `Vector` with the same items, but sorted. The sort order will be
    # determined by mapping the items through the given block to obtain sort keys,
    # and then sorting the keys according to their natural sort order.
    #
    # @example
    #   Hamster::Vector["Elephant", "Dog", "Lion"].sort_by { |e| e.size }
    #   # => Hamster::Vector["Dog", "Lion", "Elephant"]
    #
    # @return [Vector]
    def sort_by
      self.class.new(super)
    end

    # Drop the first `n` elements and return the rest in a new `Vector`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C", "D", "E", "F"].drop(2)
    #   # => Hamster::Vector["C", "D", "E", "F"]
    #
    # @param n [Integer] The number of elements to remove
    # @return [Vector]
    def drop(n)
      return self if n == 0
      return self.class.empty if n >= @size
      raise ArgumentError, "attempt to drop negative size" if n < 0
      self.class.new(flatten_suffix(@root, @levels * BITS_PER_LEVEL, n, []))
    end

    # Return only the first `n` elements in a new `Vector`.
    #
    # @example
    #   Hamster::Vector["A", "B", "C", "D", "E", "F"].take(4)
    #   # => Hamster::Vector["A", "B", "C", "D"]
    #
    # @param n [Integer] The number of elements to retain
    # @return [Vector]
    def take(n)
      return self if n >= @size
      self.class.new(super)
    end

    # Drop elements up to, but not including, the first element for which the
    # block returns `nil` or `false`. Gather the remaining elements into a new
    # `Vector`. If no block is given, an `Enumerator` is returned instead.
    #
    # @example
    #   Hamster::Vector[1, 3, 5, 7, 6, 4, 2].drop_while { |e| e < 5 }
    #   # => Hamster::Vector[5, 7, 6, 4, 2]
    #
    # @return [Vector, Enumerator]
    def drop_while
      return enum_for(:drop_while) if not block_given?
      self.class.new(super)
    end

    # Gather elements up to, but not including, the first element for which the
    # block returns `nil` or `false`, and return them in a new `Vector`. If no block
    # is given, an `Enumerator` is returned instead.
    #
    # @example
    #   Hamster::Vector[1, 3, 5, 7, 6, 4, 2].take_while { |e| e < 5 }
    #   # => Hamster::Vector[1, 3]
    #
    # @return [Vector, Enumerator]
    def take_while
      return enum_for(:take_while) if not block_given?
      self.class.new(super)
    end

    # Repetition. Return a new `Vector` built by concatenating `times` copies
    # of this one together.
    #
    # @example
    #   Hamster::Vector["A", "B"] * 3
    #   # => Hamster::Vector["A", "B", "A", "B", "A", "B"]
    #
    # @param times [Integer] The number of times to repeat the elements in this vector
    # @return [Vector]
    def *(times)
      return self.class.empty if times == 0
      return self if times == 1
      result = (to_a * times)
      result.is_a?(Array) ? self.class.new(result) : result
    end

    # Replace a range of indexes with the given object.
    #
    # @overload fill(obj)
    #   Return a new `Vector` of the same size, with every index set to `obj`.
    # @overload fill(obj, start)
    #   Return a new `Vector` with all indexes from `start` to the end of the
    #   vector set to `obj`.
    # @overload fill(obj, start, length)
    #   Return a new `Vector` with `length` indexes, beginning from `start`,
    #   set to `obj`.
    #
    # @example
    #   v = Hamster::Vector["A", "B", "C", "D", "E", "F"]
    #   v.fill("Z")
    #   # => Hamster::Vector["Z", "Z", "Z", "Z", "Z", "Z"]
    #   v.fill("Z", 3)
    #   # => Hamster::Vector["A", "B", "C", "Z", "Z", "Z"]
    #   v.fill("Z", 3, 2)
    #   # => Hamster::Vector["A", "B", "C", "Z", "Z", "F"]
    #
    # @return [Vector]
    def fill(obj, index = 0, length = nil)
      raise IndexError if index < -@size
      index += @size if index < 0
      length ||= @size - index # to the end of the array, if no length given

      if index < @size
        suffix = flatten_suffix(@root, @levels * BITS_PER_LEVEL, index, [])
        suffix.fill(obj, 0, length)
      elsif index == @size
        suffix = Array.new(length, obj)
      else
        suffix = Array.new(index - @size, nil).concat(Array.new(length, obj))
        index = @size
      end

      replace_suffix(index, suffix)
    end

    # When invoked with a block, yields all combinations of length `n` of items
    # from the `Vector`, and then returns `self`. There is no guarantee about
    # which order the combinations will be yielded in.
    #
    # If no block is given, an `Enumerator` is returned instead.
    #
    # @example
    #   v = Hamster::Vector[5, 6, 7, 8]
    #   v.combination(3) { |c| puts "Combination: #{c}" }
    #
    #   Combination: [5, 6, 7]
    #   Combination: [5, 6, 8]
    #   Combination: [5, 7, 8]
    #   Combination: [6, 7, 8]
    #   #=> Hamster::Vector[5, 6, 7, 8]
    #
    # @return [self, Enumerator]
    def combination(n)
      return enum_for(:combination, n) if not block_given?
      return self if n < 0 || @size < n
      if n == 0
        yield []
      elsif n == 1
        each { |item| yield [item] }
      elsif n == @size
        yield self.to_a
      else
        combos = lambda do |result,index,remaining|
          while @size - index > remaining
            if remaining == 1
              yield result.dup << get(index)
            else
              combos[result.dup << get(index), index+1, remaining-1]
            end
            index += 1
          end
          index.upto(@size-1) { |i| result << get(i) }
          yield result
        end
        combos[[], 0, n]
      end
      self
    end

    # When invoked with a block, yields all repeated combinations of length `n` of
    # items from the `Vector`, and then returns `self`. A "repeated combination" is
    # one in which any item from the `Vector` can appear consecutively any number of
    # times.
    #
    # There is no guarantee about which order the combinations will be yielded in.
    #
    # If no block is given, an `Enumerator` is returned instead.
    #
    # @example
    #   v = Hamster::Vector[5, 6, 7, 8]
    #   v.repeated_combination(2) { |c| puts "Combination: #{c}" }
    #
    #   Combination: [5, 5]
    #   Combination: [5, 6]
    #   Combination: [5, 7]
    #   Combination: [5, 8]
    #   Combination: [6, 6]
    #   Combination: [6, 7]
    #   Combination: [6, 8]
    #   Combination: [7, 7]
    #   Combination: [7, 8]
    #   Combination: [8, 8]
    #   # => Hamster::Vector[5, 6, 7, 8]
    #
    # @return [self, Enumerator]
    def repeated_combination(n)
      return enum_for(:repeated_combination, n) if not block_given?
      if n < 0
        # yield nothing
      elsif n == 0
        yield []
      elsif n == 1
        each { |item| yield [item] }
      elsif @size == 0
        # yield nothing
      else
        combos = lambda do |result,index,remaining|
          while index < @size-1
            if remaining == 1
              yield result.dup << get(index)
            else
              combos[result.dup << get(index), index, remaining-1]
            end
            index += 1
          end
          item = get(index)
          remaining.times { result << item }
          yield result
        end
        combos[[], 0, n]
      end
      self
    end

    # Yields all permutations of length `n` of items from the `Vector`, and then
    # returns `self`. If no length `n` is specified, permutations of all elements
    # will be yielded.
    #
    # There is no guarantee about which order the permutations will be yielded in.
    #
    # If no block is given, an `Enumerator` is returned instead.
    #
    # @example
    #   v = Hamster::Vector[5, 6, 7]
    #   v.permutation(2) { |p| puts "Permutation: #{p}" }
    #
    #   Permutation: [5, 6]
    #   Permutation: [5, 7]
    #   Permutation: [6, 5]
    #   Permutation: [6, 7]
    #   Permutation: [7, 5]
    #   Permutation: [7, 6]
    #   # => Hamster::Vector[5, 6, 7]
    #
    # @return [self, Enumerator]
    def permutation(n = @size)
      return enum_for(:permutation, n) if not block_given?
      if n < 0 || @size < n
        # yield nothing
      elsif n == 0
        yield []
      elsif n == 1
        each { |item| yield [item] }
      else
        used, result = [], []
        perms = lambda do |index|
          0.upto(@size-1) do |i|
            if !used[i]
              result[index] = get(i)
              if index < n-1
                used[i] = true
                perms[index+1]
                used[i] = false
              else
                yield result.dup
              end
            end
          end
        end
        perms[0]
      end
      self
    end

    # When invoked with a block, yields all repeated permutations of length `n` of
    # items from the `Vector`, and then returns `self`. A "repeated permutation" is
    # one where any item from the `Vector` can appear any number of times, and in
    # any position (not just consecutively)
    #
    # If no length `n` is specified, permutations of all elements will be yielded.
    # There is no guarantee about which order the permutations will be yielded in.
    #
    # If no block is given, an `Enumerator` is returned instead.
    #
    # @example
    #   v = Hamster::Vector[5, 6, 7]
    #   v.repeated_permutation(2) { |p| puts "Permutation: #{p}" }
    #
    #   Permutation: [5, 5]
    #   Permutation: [5, 6]
    #   Permutation: [5, 7]
    #   Permutation: [6, 5]
    #   Permutation: [6, 6]
    #   Permutation: [6, 7]
    #   Permutation: [7, 5]
    #   Permutation: [7, 6]
    #   Permutation: [7, 7]
    #   # => Hamster::Vector[5, 6, 7]
    #
    # @return [self, Enumerator]
    def repeated_permutation(n = @size)
      return enum_for(:repeated_permutation, n) if not block_given?
      if n < 0
        # yield nothing
      elsif n == 0
        yield []
      elsif n == 1
        each { |item| yield [item] }
      else
        result = []
        perms = lambda do |index|
          0.upto(@size-1) do |i|
            result[index] = get(i)
            if index < n-1
              perms[index+1]
            else
              yield result.dup
            end
          end
        end
        perms[0]
      end
      self
    end

    # With one or more vector or array arguments, return the cartesian product of
    # this vector's elements and those of each argument; with no arguments, return the
    # result of multiplying all this vector's items together.
    #
    # @overload product(*vectors)
    #   Return a `Vector` of all combinations of elements from this `Vector` and each
    #   of the given vectors or arrays. The length of the returned `Vector` is the product
    #   of `self.size` and the size of each argument vector or array.
    # @overload product
    #   Return the result of multiplying all the items in this `Vector` together.
    #
    # @example
    #   # Cartesian product:
    #   v1 = Hamster::Vector[1, 2, 3]
    #   v2 = Hamster::Vector["A", "B"]
    #   v1.product(v2)
    #   # => [[1, "A"], [1, "B"], [2, "A"], [2, "B"], [3, "A"], [3, "B"]]
    #
    #   # Multiply all items:
    #   Hamster::Vector[1, 2, 3, 4, 5].product  # => 120
    #
    # @return [Vector]
    def product(*vectors)
      # if no vectors passed, return "product" as in result of multiplying all items
      return super if vectors.empty?

      vectors.unshift(self)

      if vectors.any?(&:empty?)
        return block_given? ? self : []
      end

      counters = Array.new(vectors.size, 0)

      bump_counters = lambda do
        i = vectors.size-1
        counters[i] += 1
        while counters[i] == vectors[i].size
          counters[i] = 0
          i -= 1
          return true if i == -1 # we are done
          counters[i] += 1
        end
        false # not done yet
      end
      build_array = lambda do
        array = []
        counters.each_with_index { |index,i| array << vectors[i][index] }
        array
      end

      if block_given?
        while true
          yield build_array[]
          return self if bump_counters[]
        end
      else
        result = []
        while true
          result << build_array[]
          return result if bump_counters[]
        end
      end
    end

    # Assume all elements are vectors or arrays and transpose the rows and columns.
    # In other words, take the first element of each nested vector/array and gather
    # them together into a new `Vector`. Do likewise for the second, third, and so on
    # down to the end of each nested vector/array. Gather all the resulting `Vectors`
    # into a new `Vector` and return it.
    #
    # This operation is closely related to {#zip}. The result is almost the same as
    # calling {#zip} on the first nested vector/array with the others supplied as
    # arguments.
    #
    # @example
    #   Hamster::Vector[["A", 10], ["B", 20], ["C", 30]].transpose
    #   # => Hamster::Vector[Hamster::Vector["A", "B", "C"], Hamster::Vector[10, 20, 30]]
    #
    # @return [Vector]
    def transpose
      return self.class.empty if empty?
      result = Array.new(first.size) { [] }

      0.upto(@size-1) do |i|
        source = get(i)
        if source.size != result.size
          raise IndexError, "element size differs (#{source.size} should be #{result.size})"
        end

        0.upto(result.size-1) do |j|
          result[j].push(source[j])
        end
      end

      result.map! { |a| self.class.new(a) }
      self.class.new(result)
    end

    # By using binary search, finds a value from this `Vector` which meets the
    # condition defined by the provided block. Behavior is just like `Array#bsearch`.
    # See `Array#bsearch` for details.
    #
    # @example
    #   v = Hamster::Vector[1, 3, 5, 7, 9, 11, 13]
    #   # Block returns true/false for exact element match:
    #   v.bsearch { |e| e > 4 }      # => 5
    #   # Block returns number to match an element in 4 <= e <= 7:
    #   v.bsearch { |e| 1 - e / 4 }  # => 7
    #
    # @return [Object]
    def bsearch
      low, high, result = 0, @size, nil
      while low < high
        mid = (low + ((high - low) >> 1))
        val = get(mid)
        v   = yield val
        if v.is_a? Numeric
          if v == 0
            return val
          elsif v > 0
            high = mid
          else
            low = mid + 1
          end
        elsif v == true
          result = val
          high = mid
        elsif !v
          low = mid + 1
        else
          raise TypeError, "wrong argument type #{v.class} (must be numeric, true, false, or nil)"
        end
      end
      result
    end

    # Return an empty `Vector` instance, of the same class as this one. Useful if you
    # have multiple subclasses of `Vector` and want to treat them polymorphically.
    #
    # @return [Vector]
    def clear
      self.class.empty
    end

    # Return a randomly chosen item from this `Vector`. If the vector is empty, return `nil`.
    #
    # @example
    #   Hamster::Vector[1, 2, 3, 4, 5].sample  # => 2
    #
    # @return [Object]
    def sample
      get(rand(@size))
    end

    # Return a new `Vector` with only the elements at the given `indices`, in the
    # order specified by `indices`. If any of the `indices` do not exist, `nil`s will
    # appear in their places.
    #
    # @example
    #   v = Hamster::Vector["A", "B", "C", "D", "E", "F"]
    #   v.values_at(2, 4, 5)   # => Hamster::Vector["C", "E", "F"]
    #
    # @param indices [Array] The indices to retrieve and gather into a new `Vector`
    # @return [Vector]
    def values_at(*indices)
      self.class.new(indices.map { |i| get(i) }.freeze)
    end

    # Return the index of the last element which is equal to the provided object,
    # or for which the provided block returns true.
    #
    # @overload rindex(obj)
    #   Return the index of the last element in this `Vector` which is `#==` to `obj`.
    # @overload rindex { |item| ... }
    #   Return the index of the last element in this `Vector` for which the block
    #   returns true. (Iteration starts from the last element, counts back, and
    #   stops as soon as a matching element is found.)
    #
    # @example
    #   v = Hamster::Vector[7, 8, 9, 7, 8, 9]
    #   v.rindex(8)               # => 4
    #   v.rindex { |e| e.even? }  # => 4
    #
    # @return [Index]
    def rindex(obj = (missing_arg = true))
      i = @size - 1
      if missing_arg
        if block_given?
          reverse_each { |item| return i if yield item; i -= 1 }
          nil
        else
          enum_for(:rindex)
        end
      else
        reverse_each { |item| return i if item == obj; i -= 1 }
        nil
      end
    end

    # Assumes all elements are nested, indexable collections, and searches through them,
    # comparing `obj` with the first element of each nested collection. Return the
    # first nested collection which matches, or `nil` if none is found.
    #
    # @example
    #   v = Hamster::Vector[["A", 10], ["B", 20], ["C", 30]]
    #   v.assoc("B")  # => ["B", 20]
    #
    # @param obj [Object] The object to search for
    # @return [Object]
    def assoc(obj)
      each { |array| return array if obj == array[0] }
      nil
    end

    # Assumes all elements are nested, indexable collections, and searches through them,
    # comparing `obj` with the second element of each nested collection. Return the
    # first nested collection which matches, or `nil` if none is found.
    #
    # @example
    #   v = Hamster::Vector[["A", 10], ["B", 20], ["C", 30]]
    #   v.rassoc(20)  # => ["B", 20]
    #
    # @param obj [Object] The object to search for
    # @return [Object]
    def rassoc(obj)
      each { |array| return array if obj == array[1] }
      nil
    end

    # Return an `Array` with the same elements, in the same order. The returned
    # `Array` may or may not be frozen.
    #
    # @return [Array]
    def to_a
      if @levels == 0
        @root
      else
        flatten_node(@root, @levels * BITS_PER_LEVEL, [])
      end
    end

    # Return true if `other` has the same type and contents as this `Vector`.
    #
    # @param other [Object] The collection to compare with
    # @return [Boolean]
    def eql?(other)
      return true if other.equal?(self)
      return false unless instance_of?(other.class) && @size == other.size
      @root.eql?(other.instance_variable_get(:@root))
    end

    # See `Object#hash`.
    # @return [Integer]
    def hash
      reduce(0) { |hash, item| (hash << 5) - hash + item.hash }
    end

    # @return [::Array]
    # @private
    def marshal_dump
      to_a
    end

    # @private
    def marshal_load(array)
      initialize(array.freeze)
    end

    private

    def traverse_depth_first(node, level, &block)
      return node.each(&block) if level == 0
      node.each { |child| traverse_depth_first(child, level - 1, &block) }
    end

    def reverse_traverse_depth_first(node, level, &block)
      return node.reverse_each(&block) if level == 0
      node.reverse_each { |child| reverse_traverse_depth_first(child, level - 1, &block) }
    end

    def leaf_node_for(node, bitshift, index)
      while bitshift > 0
        node = node[(index >> bitshift) & INDEX_MASK]
        bitshift -= BITS_PER_LEVEL
      end
      node
    end

    def update_root(index, item)
      root, levels = @root, @levels
      while index >= (1 << (BITS_PER_LEVEL * (levels + 1)))
        root = [root].freeze
        levels += 1
      end
      new_root = update_leaf_node(root, levels * BITS_PER_LEVEL, index, item)
      if new_root.equal?(root)
        self
      else
        self.class.alloc(new_root, @size > index ? @size : index + 1, levels)
      end
    end

    def update_leaf_node(node, bitshift, index, item)
      slot_index = (index >> bitshift) & INDEX_MASK
      if bitshift > 0
        old_child = node[slot_index] || []
        item = update_leaf_node(old_child, bitshift - BITS_PER_LEVEL, index, item)
      end
      existing_item = node[slot_index]
      if existing_item.equal?(item)
        node
      else
        node.dup.tap { |n| n[slot_index] = item }.freeze
      end
    end

    def flatten_range(node, bitshift, from, to)
      from_slot = (from >> bitshift) & INDEX_MASK
      to_slot   = (to   >> bitshift) & INDEX_MASK

      if bitshift == 0 # are we at the bottom?
        node.slice(from_slot, to_slot-from_slot+1)
      elsif from_slot == to_slot
        flatten_range(node[from_slot], bitshift - BITS_PER_LEVEL, from, to)
      else
        # the following bitmask can be used to pick out the part of the from/to indices
        #   which will be used to direct path BELOW this node
        mask   = ((1 << bitshift) - 1)
        result = []

        if from & mask == 0
          flatten_node(node[from_slot], bitshift - BITS_PER_LEVEL, result)
        else
          result.concat(flatten_range(node[from_slot], bitshift - BITS_PER_LEVEL, from, from | mask))
        end

        (from_slot+1).upto(to_slot-1) do |slot_index|
          flatten_node(node[slot_index], bitshift - BITS_PER_LEVEL, result)
        end

        if to & mask == mask
          flatten_node(node[to_slot], bitshift - BITS_PER_LEVEL, result)
        else
          result.concat(flatten_range(node[to_slot], bitshift - BITS_PER_LEVEL, to & ~mask, to))
        end

        result
      end
    end

    def flatten_node(node, bitshift, result)
      if bitshift == 0
        result.concat(node)
      elsif bitshift == BITS_PER_LEVEL
        node.each { |a| result.concat(a) }
      else
        bitshift -= BITS_PER_LEVEL
        node.each { |a| flatten_node(a, bitshift, result) }
      end
      result
    end

    def subsequence(from, length)
      return nil if from > @size || from < 0 || length < 0
      length = @size - from if @size < from + length
      return self.class.empty if length == 0
      self.class.new(flatten_range(@root, @levels * BITS_PER_LEVEL, from, from + length - 1))
    end

    def flatten_suffix(node, bitshift, from, result)
      from_slot = (from >> bitshift) & INDEX_MASK

      if bitshift == 0
        if from_slot == 0
          result.concat(node)
        else
          result.concat(node.slice(from_slot, 32)) # entire suffix of node. excess length is ignored by #slice
        end
      else
        mask = ((1 << bitshift) - 1)
        if from & mask == 0
          from_slot.upto(node.size-1) do |i|
            flatten_node(node[i], bitshift - BITS_PER_LEVEL, result)
          end
        elsif child = node[from_slot]
          flatten_suffix(child, bitshift - BITS_PER_LEVEL, from, result)
          (from_slot+1).upto(node.size-1) do |i|
            flatten_node(node[i], bitshift - BITS_PER_LEVEL, result)
          end
        end
        result
      end
    end

    def replace_suffix(from, suffix)
      # new suffix can go directly after existing elements
      raise IndexError if from > @size
      root, levels = @root, @levels

      if (from >> (BITS_PER_LEVEL * (@levels + 1))) != 0
        # index where new suffix goes doesn't fall within current tree
        # we will need to deepen tree
        root = [root].freeze
        levels += 1
      end

      new_size = from + suffix.size
      root = replace_node_suffix(root, levels * BITS_PER_LEVEL, from, suffix)

      if !suffix.empty?
        levels.times { suffix = suffix.each_slice(32).to_a }
        root.concat(suffix)
        while root.size > 32
          root = root.each_slice(32).to_a
          levels += 1
        end
      else
        while root.size == 1 && levels > 0
          root = root[0]
          levels -= 1
        end
      end

      self.class.alloc(root.freeze, new_size, levels)
    end

    def replace_node_suffix(node, bitshift, from, suffix)
      from_slot = (from >> bitshift) & INDEX_MASK

      if bitshift == 0
        if from_slot == 0
          suffix.shift(32)
        else
          node.take(from_slot).concat(suffix.shift(32 - from_slot))
        end
      else
        mask = ((1 << bitshift) - 1)
        if from & mask == 0
          if from_slot == 0
            new_node = suffix.shift(32 * (1 << bitshift))
            while bitshift != 0
              new_node = new_node.each_slice(32).to_a
              bitshift -= BITS_PER_LEVEL
            end
            new_node
          else
            result = node.take(from_slot)
            remainder = suffix.shift((32 - from_slot) * (1 << bitshift))
            while bitshift != 0
              remainder = remainder.each_slice(32).to_a
              bitshift -= BITS_PER_LEVEL
            end
            result.concat(remainder)
          end
        elsif child = node[from_slot]
          result = node.take(from_slot)
          result.push(replace_node_suffix(child, bitshift - BITS_PER_LEVEL, from, suffix))
          remainder = suffix.shift((31 - from_slot) * (1 << bitshift))
          while bitshift != 0
            remainder = remainder.each_slice(32).to_a
            bitshift -= BITS_PER_LEVEL
          end
          result.concat(remainder)
        else
          raise "Shouldn't happen"
        end
      end
    end
  end

  # The canonical empty `Vector`. Returned by `Hamster.vector` and `Vector[]` when
  # invoked with no arguments; also returned by `Vector.empty`. Prefer using this
  # one rather than creating many empty vectors using `Vector.new`.
  #
  EmptyVector = Hamster::Vector.empty
end
