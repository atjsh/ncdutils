# SPDX-FileCopyrightText: Yoran Heling <projects@yorhel.nl>
# SPDX-License-Identifier: AGPL-3.0-only
require "bit_array"

module NcduFile

  @[Link("libzstd")]
  lib ZSTD
    fun decompress = ZSTD_decompress(dst: UInt8*, dstCapacity: LibC::SizeT, src: UInt8*, compressedSize: LibC::SizeT) : LibC::SizeT
    fun getFrameContentSize = ZSTD_getFrameContentSize(src: UInt8*, srcSize: LibC::SizeT) : LibC::ULongLong
  end

  # Block header/footer
  struct Hdr
    @raw : UInt32

    TYPE_SHIFT = 28
    LEN_MASK = (1<<TYPE_SHIFT) - 1

    def initialize(@raw)
    end

    def self.from_io(io, format)
      new io.read_bytes UInt32, IO::ByteFormat::BigEndian
    end

    def len
      (@raw & LEN_MASK).to_i32
    end

    def type
      @raw >> TYPE_SHIFT
    end

    def data?
      type == 0
    end

    def index?
      type == 1
    end

    def to_s(io)
      @raw.to_s io, 16
    end
  end

  # Index pointer
  struct Ptr
    @raw : UInt64

    OFFSET_SHIFT = 24
    LEN_MASK = (1<<OFFSET_SHIFT) - 1

    def initialize(@raw)
    end

    def initialize(offset, len)
      @raw = (offset.to_u64 << OFFSET_SHIFT) + len
    end

    def self.from_io(io, format)
      new io.read_bytes UInt64, IO::ByteFormat::BigEndian
    end

    def len
      (@raw & LEN_MASK).to_i32
    end

    def offset
      @raw >> OFFSET_SHIFT
    end

    def empty?
      @raw == 0
    end

    def to_s(io)
      @raw.to_s io, 16
    end
  end

  # Absolute Itemref
  struct Ref
    property raw : UInt64

    BLOCK_SHIFT = 24
    OFFSET_MASK = (1<<BLOCK_SHIFT) - 1

    def initialize(@raw)
    end

    def initialize(block, offset)
      @raw = (block.to_u64 << BLOCK_SHIFT) + offset
    end

    def self.from_io(io, format)
      new io.read_bytes UInt64, IO::ByteFormat::BigEndian
    end

    def offset
      (raw & OFFSET_MASK).to_i32
    end

    def block
      raw >> BLOCK_SHIFT
    end

    def to_s(io)
      io << "i#"
      raw.to_s io, 16, precision: 10
    end
  end


  class Item
    property ref : Ref # Ref to current item
    property type : Int32 = ~0
    property name : String = "" # Might not validate as UTF-8
    property prev : Ref?
    property asize : UInt64 = 0
    property dsize : UInt64 = 0
    property dev : UInt64 = 0
    property rderr : Bool?
    property cumasize : UInt64 = 0
    property cumdsize : UInt64 = 0
    property shrasize : UInt64 = 0
    property shrdsize : UInt64 = 0
    property items : UInt64 = 0
    property sub : Ref?
    property ino : UInt64 = 0
    property nlink : UInt32 = 0
    property uid : UInt32?
    property gid : UInt32?
    property mode : UInt16?
    property mtime : UInt64?

    enum CborMajor : UInt8
      PosInt; NegInt; Bytes; Text; Array; Map; Tag; Simple
    end

    def initialize(@ref)
    end

    # Custom CBOR parser. I know, I know, there exists a crystal-cbor shard, but
    # that one doesn't make it easy to validate the various constraints I
    # documented for the Item encoding.
    # This is an ugly parser, but ought to be conforming to the spec.  I've
    # only tested this against ncdu's output so far, though, so it's pretty
    # much guaranteed to have bugs. :(
    def self.parse_cbor(io : IO::Memory, &)
      stack = [1] of (UInt16 | CborMajor | Nil)
      while !stack.empty?
        first = io.read_bytes UInt8
        major = CborMajor.new first >> 5
        minor = first & 0x1f
        arg : UInt64 | Nil = nil

        # Parse header byte + value
        case minor
        when 0x00..0x17 then arg = minor.to_u64
        when 0x18 then arg = io.read_bytes(UInt8).to_u64
        when 0x19 then arg = io.read_bytes(UInt16, IO::ByteFormat::BigEndian).to_u64
        when 0x1a then arg = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_u64
        when 0x1b then arg = io.read_bytes(UInt64, IO::ByteFormat::BigEndian).to_u64
        when 0x1f
          case major
          when .pos_int?, .neg_int?, .tag?
            raise "Invalid CBOR"
          when .simple?
            raise "Invalid CBOR" if stack.last.is_a? UInt16
          end
        else
          raise "Invalid CBOR"
        end
        raise "Invalid CBOR" if stack.last.is_a? CborMajor && (arg.nil? || stack.last != major)

        # Read text/bytes argument
        data = nil
        if !arg.nil? && (major.text? || major.bytes?)
          raise "Invalid CBOR" if arg > (1<<24)
          data = io.read_string arg
          raise "Invalid CBOR" if major.text? && !data.valid_encoding?
        end

        yield stack.size - 1, major, arg, data

        # Update parsing state
        if arg.nil? && (major.text? || major.bytes?)
          stack.push major
        elsif (major.array? || major.map?) && (arg.nil? || arg > 0)
          if arg.nil?
            stack.push nil
          else
            raise "Invalid CBOR" if arg >= (1<<15)
            stack.push (major.map? ? arg * 2 : arg).to_u16
          end
        elsif !major.tag?
          stack.pop if first == 0xff
          loop do
            last = stack.last?
            if last.is_a? UInt16
              stack[stack.size-1] = last - 1
              break if last > 1
              stack.pop
            else
              break
            end
          end
        end
      end
    end

    # Wonderfully unhygenic macros to help with field parsing.
    macro m_uint(f, bits=64)
      if major.pos_int? && arg.not_nil! <= UInt{{bits}}::MAX
        item.{{f}} = arg.not_nil!.to_u{{bits}}
      else
        raise "Invalid '#{ {{ f.stringify }} }' field for item #{ref}: #{major} #{arg}"
      end
    end

    macro m_ref(f)
      if major.pos_int?
        item.{{f}} = Ref.new arg.not_nil!
      elsif major.neg_int? && arg.not_nil! < ref.offset
        item.{{f}} = Ref.new ref.block, ref.offset - arg.not_nil! - 1
      else
        raise "Invalid '#{ {{ f.stringify }} }' itemref for item #{ref}: #{major} #{arg}"
      end
    end

    def self.read(io, ref, warn_unknown_fields = false) : Item
      item = new ref
      key = nil

      parse_cbor io do |depth, major, arg, data|
        raise "Invalid item at #{ref}: #{major}" if depth == 0 && !major.map?
        next if depth == 0 || depth > 1 # We don't have any fields that support nesting, so can safely skip
        next if major.simple? && arg.nil?  # Ignore the 'break'

        if key.nil?
          if major.pos_int? && arg.not_nil! <= 18
            key = arg.not_nil!.to_i32
          else
            STDERR.puts "WARNING: Unknown field in item #{ref}: #{major} #{arg} #{data}" if warn_unknown_fields
            key = -1
          end
          next
        end

        case key
        when -1 then next
        when 0
          case major
          when .pos_int? then item.type = arg.not_nil! > 3 ? 2 : arg.not_nil!.to_i32
          when .neg_int? then item.type = arg.not_nil! > 3 ? -2 : -(arg.not_nil!.to_i32) - 1
          else raise "Invalid 'type' field for item #{ref}: #{major} #{arg} #{data}"
          end
        when 1
          # 'data' is only defined for definite-length text or byte strings, so testing for that is sufficient
          item.name = data || raise "Invalid 'name' field for item #{ref}: #{major} #{arg}"
        when 2 then m_ref prev
        when 3 then m_uint asize
        when 4 then m_uint dsize
        when 5 then m_uint dev
        when 6
          if major.simple? && (arg == 20 || arg == 21)
            item.rderr = arg == 21
          else
            raise "Invalid 'rderr' field for item #{ref}: #{major} #{arg}"
          end
        when 7 then m_uint cumasize
        when 8 then m_uint cumdsize
        when 9 then m_uint shrasize
        when 10 then m_uint shrdsize
        when 11 then m_uint items
        when 12 then m_ref sub
        when 13 then m_uint ino
        when 14 then m_uint nlink, 32
        when 15 then m_uint uid, 32
        when 16 then m_uint gid, 32
        when 17 then m_uint mode, 16
        when 18 then m_uint mtime
        else abort "Unreachable"
        end

        key = nil
      end
      raise "Missing or empty 'name' for item #{ref}" if item.name == ""
      raise "Missing 'type' for item #{ref}" if item.type == ~0
      # TODO: Validate the presence of optional fields for the wrong type? Ncdu doesn't really care...
      item
    end

    def to_s(io)
      io << ref
      io << "{type=" << type
      io << " prev=" << prev if prev
      io << " asize=" << asize if asize != 0
      io << " dsize=" << dsize if dsize != 0
      io << " dev=" << dev if dev != 0
      io << " rderrr=" << rderr if rderr
      io << " cumasize=" << cumasize if cumasize != 0
      io << " cumdsize=" << cumdsize if cumdsize != 0
      io << " shrasize=" << shrasize if shrasize != 0
      io << " shrdsize=" << shrdsize if shrdsize != 0
      io << " items=" << items if items != 0
      io << " sub=" << sub if sub
      io << " ino=" << ino if ino != 0
      io << " nlink=" << nlink if nlink != 0
      io << " uid=" << uid if uid
      io << " gid=" << gid if gid
      io << " mode=" << mode if mode
      io << " mtime=" << mtime if mtime
      io << " name=" << name << "}"
    end
  end

  # Low-ish level binary export file reader
  class Reader
    @file : File
    @index : Slice(Ptr)
    getter root : Ref
    def initialize(path)
      @file = File.new path
      @file.read_buffering = false
      header = @file.read_string 8
      raise "Unrecognized file type" if header != "\xbfncduEX1"

      # Find the start of the index block
      @file.seek -4, IO::Seek::End
      index_hdr = @file.read_bytes Hdr
      raise "Invalid index block" if !index_hdr.index? || index_hdr.len < 24 || index_hdr.len & 7 != 0
      @file.seek 0 - index_hdr.len, IO::Seek::End
      index_start = @file.tell

      # Read the index block
      @file.read_buffering = true
      raise "Invalid index block" if index_hdr != @file.read_bytes Hdr
      @index = Slice(Ptr).new(((index_hdr.len - 16)>>3).to_i32, read_only: true) do |i|
        ptr = @file.read_bytes Ptr
        raise "Invalid pointer at index #{i} (#{ptr})" if !ptr.empty? && (ptr.len <= 12 || ptr.offset >= index_start - 12)
        ptr
      end
      @root = @file.read_bytes Ref
      @file.read_buffering = false
    end

    def close
      @file.close
    end

    def read_block(idx)
      raise "Invalid block index #{idx}" if idx >= @index.size || @index[idx].empty?
      @file.seek @index[idx].offset + 8, IO::Seek::Set
      compressed = @file.read_string @index[idx].len - 12
      len = ZSTD.getFrameContentSize compressed.to_unsafe, compressed.bytesize
      raise "Invalid decompressed size for block #{idx} (#{len})" if len <= 0 || len >= (1<<24)
      data = Pointer(UInt8).malloc len
      ret = ZSTD.decompress data, len, compressed.to_unsafe, compressed.bytesize
      raise "Error decompressing block #{idx}: #{ret}" if ret != len
      Slice(UInt8).new data, len, read_only: true
    end

    def validate_items(idx, data, items_seen, list_items, warn_unknown_fields)
      io = IO::Memory.new data
      while io.tell < data.size
        item = Item.read io, Ref.new(idx, io.tell), warn_unknown_fields
        puts "  #{item}" if list_items
        items_seen.update(item.ref) { |v| v + 1 }

        item.prev.try do |r|
          break if r.raw == 0 && item.ref == root # BUG in ncdu 2.6: root item has 'prev=0'
          items_seen.update(r) do |v|
            raise "Item #{r} is referenced from multiple places (second = #{item.ref}.prev)" if v > 1
            v + 2
          end
        end

        item.sub.try do |r|
          items_seen.update(r) do |v|
            raise "Item #{r} is referenced from multiple places (second = #{item.ref}.sub)" if v > 1
            v + 2
          end
        end
      end
    end

    def validate(*, list_blocks = false, list_items = false, warn_unknown_blocks = true, warn_unknown_fields = true)
      blocks_seen = BitArray.new @index.size
      items_seen = Hash(Ref, UInt8).new 0, 4096 # bits: 1 = item seen, 2 = ref to item seen
      items_seen[root] = 2

      @file.seek 8, IO::Seek::Set
      loop do
        off = @file.tell
        hdr = @file.read_bytes Hdr
        if hdr.index?
          puts "#{off}: Index block, length = #{hdr.len}" if list_blocks
          break # already validated in initialize()
        end

        if !hdr.data?
          puts "#{off}: Unknown block, type = #{hdr.type}, length = #{hdr.len}" if list_blocks
          STDERR.puts "WARNING: Unknown block type #{hdr.type} at offset #{off} (length = #{hdr.len})" if warn_unknown_blocks
          raise "Invalid data block length at offset #{off} (#{hdr.len})" if hdr.len < 8
          @file.seek hdr.len - 8, IO::Seek::Current
          foot = @file.read_bytes Hdr
          raise "Block at offset #{off} has mismatched header/footer (#{hdr} vs. #{foot})" if hdr != foot
          next
        end

        # data block
        raise "Invalid data block length at offset #{off} (#{hdr.len})" if hdr.len <= 12
        idx = @file.read_bytes UInt32, IO::ByteFormat::BigEndian
        raise "Data block #{idx} at offset #{off} is not listed in the index" if idx >= @index.size
        idxptr = Ptr.new off, hdr.len
        raise "Data block #{idx} at offset #{off} has invalid index pointer (expected #{idxptr} got #{@index[idx]})" if idxptr != @index[idx]
        data = read_block idx
        puts "#{off}: Data block #{idx}, length = #{hdr.len}, uncompressed size = #{data.size}" if list_blocks

        # Assumption: file position is at the end of the data after read_block()
        foot = @file.read_bytes Hdr
        raise "Block at offset #{off} has mismatched header/footer (#{hdr} vs. #{foot})" if hdr != foot
        blocks_seen[idx] = true
        validate_items idx, data, items_seen, list_items, warn_unknown_fields
      end

      @index.each_with_index do |ptr, i|
        raise "Data block #{i} not found in the file, but the index lists it at #{ptr}" if !ptr.empty? && !blocks_seen[i]
      end
      items_seen.each do |ref, v|
        raise "No references found to item #{ref}" if v == 1
        raise "Invalid reference found to #{ref}" if v == 2
      end
    end
  end
end
