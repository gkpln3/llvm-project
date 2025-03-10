//===- LinalgOps.td - Linalg dialect ops -------------------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This is the operation definition file for linear algebra operations.
//
//===----------------------------------------------------------------------===//

#ifndef LINALG_OPS
#define LINALG_OPS

include "mlir/Dialect/Linalg/IR/LinalgBase.td"
include "mlir/Interfaces/ControlFlowInterfaces.td"
include "mlir/Interfaces/InferTypeOpInterface.td"
include "mlir/Interfaces/LoopLikeInterface.td"
include "mlir/Interfaces/SideEffectInterfaces.td"
include "mlir/Interfaces/TilingInterface.td"
include "mlir/Interfaces/ViewLikeInterface.td"

// Base class for Linalg dialect ops that do not correspond to library calls.
class Linalg_Op<string mnemonic, list<OpTrait> traits = []> :
    Op<Linalg_Dialect, mnemonic, traits> {
  // For every linalg op, there needs to be a:
  //   * void print(OpAsmPrinter &p, ${C++ class of Op} op)
  //   * LogicalResult verify(${C++ class of Op} op)
  //   * ParseResult parse${C++ class of Op}(OpAsmParser &parser,
  //                                         OperationState &result)
  // functions.
  let printer = [{ return ::print(p, *this); }];
  let verifier = [{ return ::verify(*this); }];
  let parser = [{ return ::parse$cppClass(parser, result); }];
}

def Linalg_InitTensorOp : Linalg_Op<"init_tensor",
    [NoSideEffect,
     DeclareOpInterfaceMethods<ReifyRankedShapedTypeOpInterface>]> {
  let summary = "operation to define a tensor of particular value";

  let description = [{
    `linalg.init_tensor` is an operation that materializes a tensor of
    a given shape. The shape could be dynamic or static.
  }];

  let arguments =
    (ins Variadic<Index>:$sizes, I64ArrayAttr:$static_sizes);

  let results = (outs AnyTensor:$result);

  let assemblyFormat = [{
    custom<OperandsOrIntegersSizesList>($sizes, $static_sizes) attr-dict
    `:` type($result)
  }];

  let verifier = [{ return ::verify(*this); }];

  let extraClassDeclaration = [{
    static StringRef getStaticSizesAttrName() {
      return "static_sizes";
    }

    RankedTensorType getType() {
      return getResult().getType().cast<RankedTensorType>(); }

    // Infer the shape of the result tensor given the static shapes
    // and element type of the result tensor.
    static Type inferResultType(ArrayRef<int64_t> staticSizes, Type elementType,
                                Attribute encoding = {});

    // Return true if the size of the tensor is dynamic at `idx`
    bool isDynamicSize(unsigned idx) {
      APInt v = *(static_sizes().getAsValueRange<IntegerAttr>().begin() + idx);
      return ShapedType::isDynamic(v.getSExtValue());
    }

    // Assert that the size of the result tensor is static at `idx`
    // and return the shape.
    int64_t getStaticSize(unsigned idx) {
      assert(!isDynamicSize(idx) && "expected static size");
      APInt v = *(static_sizes().
          template getAsValueRange<IntegerAttr>().begin() + idx);
        return v.getSExtValue();
    }

    // Return the argument position that contains the dynamic size of
    // the tensor at dimension `idx`. Asserts that the shape is
    // dynamic at that `idx`.
    unsigned getIndexOfDynamicSize(unsigned idx) {
      assert(isDynamicSize(idx) && "expected dynamic size");
      return std::count_if(
          static_sizes().getValue().begin(),
          static_sizes().getValue().begin() + idx,
          [&](Attribute attr) {
            return ShapedType::isDynamic(attr.cast<IntegerAttr>().getInt());
          });
    }

    // Return the Value of the dynamic size of the tensor at dimension
    // `idx`. Asserts that the shape is dynamic at that `idx.
    Value getDynamicSize(unsigned idx) {
      return getOperand(getIndexOfDynamicSize(idx));
    }
  }];

  let builders = [
    OpBuilder<(ins "ValueRange":$shape,
                  "ArrayRef<int64_t>":$staticShape, "Type":$elementType),
    [{
      build($_builder, $_state,
            InitTensorOp::inferResultType(staticShape, elementType),
            shape, $_builder.getI64ArrayAttr(staticShape));
    }]>,
    OpBuilder<(ins "ValueRange":$shape, "Type":$elementType),
    [{
      SmallVector<int64_t, 4> staticShape(
        shape.size(), ShapedType::kDynamicSize);
      build($_builder, $_state, shape, staticShape, elementType);
    }]>,
    OpBuilder<(ins "ArrayRef<int64_t>":$staticShape, "Type":$elementType),
    [{
      build($_builder, $_state, ValueRange{}, staticShape, elementType);
    }]>,
    OpBuilder<(ins "ArrayRef<OpFoldResult>":$sizes, "Type":$elementType,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attrs)>
  ];

  let hasCanonicalizer = 1;
}

def Linalg_PadTensorOp : Linalg_Op<"pad_tensor",
    [AttrSizedOperandSegments, NoSideEffect,
     DeclareOpInterfaceMethods<ReifyRankedShapedTypeOpInterface>,
     DeclareOpInterfaceMethods<TilingInterface,
         ["getDestinationOperands", "getLoopIteratorTypes", "getIterationDomain",
          "getTiledImplementation"]>]> {
  let summary = "tensor pad operation";
  let description = [{
    `linalg.pad_tensor` is an operation that pads the `source` tensor
    with given `low` and `high` padding config.

    The PadTensor operation supports the following arguments:

    * source: the "base" tensor on which to pad.
    * low: A list contains the padding along the start of each
           dimension, i.e `low`.
    * high: A list contains the padding along the end of each
            dimension, i.e. `high`.
    * nofold: indicates that the operation should not be folded when source and
              result types are equal.

    The result tensor dimensions are `low` + `dim` + `high` along that
    dimension. The number of elements of `low` and `high` must match
    the rank of the input tensor. They can be either a constant or a
    dynamic value.

    The region of the `pad_tensor` operation returns the value to use
    for the padding. The arguments of the region represent the index
    of the source being accessed. There should be as many arguments as
    the rank of the `source` tensor. The value `yield`-ed by the
    region is used as the value of the view at the given position.

    If `nofold` is set, the padding operation will not be folded away even
    if the source type and the padded type have the same static shape. This can
    be used, e.g., for packing or promotion to faster memory.

    Example 1:

    ```mlir
      %pad_value = ... : f32
      %0 = linalg.pad_tensor %0 low[1, 2] high[2, 3] {
      ^bb0(%arg0 : index, %arg1 : index):
        linalg.yield %pad_value : f32
      } : tensor<?x?xf32> to tensor<?x?xf32>
    ```

    Example 2:

    ```mlir
      %pad_value = ... : f32
      %0 = linalg.pad_tensor %arg0 low[2, %arg1, 3, 3] high[3, 3, %arg1, 2] {
      ^bb0(%arg2: index, %arg3: index, %arg4: index, %arg5: index):
          linalg.yield %pad_value : f32
      } : tensor<1x2x2x?xf32> to tensor<6x?x?x?xf32>
    ```

    Example 3:

    ```mlir
      %pad_value = ... : f32
      %0 = linalg.pad_tensor %arg0 low[0, 0] high[%ub0, %ub1] {
      ^bb0(%arg1: index, %arg2: index):
        linalg.yield %pad_value : f32
      } : tensor<2x3xf32> to tensor<?x?xf32>
    ```

    Example 4:

    ```mlir
      // Force a padded value to be always exist with `nofold`.
      %pad_value = ... : f32
      %0 = linalg.pad_tensor %arg0 nofold low[0, 0] high[0, 0] {
      ^bb0(%arg1: index, %arg2: index):
        linalg.yield %pad_value : f32
      } : tensor<2x3xf32> to tensor<2x3xf32>
    ```
  }];

  let arguments = (ins
    AnyTensor:$source,
    Variadic<Index>:$low,
    Variadic<Index>:$high,
    I64ArrayAttr:$static_low,
    I64ArrayAttr:$static_high,
    UnitAttr:$nofold);

  let regions = (region SizedRegion<1>:$region);

  let results = (outs AnyTensor:$result);

  // TODO: Remove custom<InferType> when AllTypesMatch supports opt. operands.
  let assemblyFormat = [{
    $source
    (`nofold` $nofold^)?
    `low` `` custom<OperandsOrIntegersSizesList>($low, $static_low)
    `high` `` custom<OperandsOrIntegersSizesList>($high, $static_high)
    $region attr-dict `:` type($source) `to` type($result)
  }];

  let extraClassDeclaration = [{
    static StringRef getStaticLowAttrName() {
      return "static_low";
    }

    static StringRef getStaticHighAttrName() {
      return "static_high";
    }

    RankedTensorType getSourceType() {
      return source().getType().cast<RankedTensorType>();
    }
    RankedTensorType getResultType() {
      return getResult().getType().cast<RankedTensorType>();
    }

    // Infer the shape of the result tensor given the type of the source tensor
    // and paddings. Known result dimensions that cannot necessarily be inferred
    // from low/high padding sizes can be optionally specified. Those will be
    // considered when computing the result type.
    static RankedTensorType inferResultType(
                                RankedTensorType sourceType,
                                ArrayRef<int64_t> staticLow,
                                ArrayRef<int64_t> staticHigh,
                                ArrayRef<int64_t> resultShape = {});

    // Return a PadTensorOp that pads `source` to `type` size where the static
    // sizes are assumed to be greater than the dynamic sizes. The op performs
    // "high" padding (i.e. it adds trailing padding values until the desired
    // size is met).
    static linalg::PadTensorOp createPadHighOp(
        Type type, Value source, Value pad, bool nofold, Location loc,
        OpBuilder & builder);

    // Return a PadTensorOp that pads `source to `type` size with `pad` value.
    // I.e., a block will be created and the `pad` value will be yielded
    // directly. If the type passed is nullptr, it is inferred.
    static linalg::PadTensorOp createPadScalarOp(
        Type type, Value source, Value pad, ArrayRef<OpFoldResult> low,
        ArrayRef<OpFoldResult> high, bool nofold, Location loc,
        OpBuilder & builder);

    // Return the pad value if it is a constant. Return null value otherwise.
    Value getConstantPaddingValue();

    // Return a vector of all the static or dynamic values (low/high padding) of
    // the op.
    inline SmallVector<OpFoldResult> getMixedPadImpl(ArrayAttr staticAttrs,
                                                     ValueRange values) {
      SmallVector<OpFoldResult> res;
      unsigned numDynamic = 0;
      unsigned count = staticAttrs.size();
      for (unsigned idx = 0; idx < count; ++idx) {
        if (ShapedType::isDynamic(staticAttrs[idx].cast<IntegerAttr>().getInt()))
          res.push_back(values[numDynamic++]);
        else
          res.push_back(staticAttrs[idx]);
      }
      return res;
    }
    SmallVector<OpFoldResult> getMixedLowPad() {
      return getMixedPadImpl(static_low(), low());
    }
    SmallVector<OpFoldResult> getMixedHighPad() {
      return getMixedPadImpl(static_high(), high());
    }
    // Return true if low padding is guaranteed to be 0.
    bool hasZeroLowPad() {
      return llvm::all_of(getMixedLowPad(), [](OpFoldResult ofr) {
        return getConstantIntValue(ofr) == static_cast<int64_t>(0);
      });
    }
    // Return true if high padding is guaranteed to be 0.
    bool hasZeroHighPad() {
      return llvm::all_of(getMixedHighPad(), [](OpFoldResult ofr) {
        return getConstantIntValue(ofr) == static_cast<int64_t>(0);
      });
    }
  }];

  let builders = [
    // Build a PadTensorOp with mixed static and dynamic entries.
    OpBuilder<(ins "Value":$source, "ArrayRef<int64_t>":$staticLow,
      "ArrayRef<int64_t>":$staticHigh, "ValueRange":$low, "ValueRange":$high,
      CArg<"bool", "false">:$nofold,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attrs)>,
    // Build a PadTensorOp with all dynamic entries.
    OpBuilder<(ins "Value":$source, "ValueRange":$low, "ValueRange":$high,
      CArg<"bool", "false">:$nofold,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attrs)>,
    // Build a PadTensorOp with mixed static and dynamic entries and custom
    // result type. If the type passed is nullptr, it is inferred.
    OpBuilder<(ins "Type":$resultType, "Value":$source,
      "ArrayRef<OpFoldResult>":$low, "ArrayRef<OpFoldResult>":$high,
      CArg<"bool", "false">:$nofold,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attrs)>,
  ];

  let hasCanonicalizer = 1;
  let hasFolder = 1;
}

def Linalg_YieldOp : Linalg_Op<"yield", [NoSideEffect, ReturnLike, Terminator]>,
    Arguments<(ins Variadic<AnyType>:$values)> {
  let summary = "Linalg yield operation";
  let description = [{
    `linalg.yield` is a special terminator operation for blocks inside regions
    in `linalg` generic ops. It returns values to the immediately enclosing
    `linalg` generic op.

    Example:

    ```mlir
    linalg.yield %f0, %f1 : f32, f32
    ```
  }];
  let builders = [OpBuilder<(ins), [{ /* nothing to do */ }]>];
}

def Linalg_TiledLoopOp : Linalg_Op<"tiled_loop", [
     AttrSizedOperandSegments,
     DeclareOpInterfaceMethods<LoopLikeOpInterface>,
     RecursiveSideEffects,
     SingleBlockImplicitTerminator<"linalg::YieldOp">
    ]> {
  let summary = "Linalg tiled loop operation";
  let description = [{
    This is a loop-like operation with additional properties. The arguments
    also include the input and the output tensors or memrefs and the attributes
    to specify the iterator types.

    Parsing TiledLoopOp will set all elements of the `iterator_types` attribute
    to "parallel" type, when it is absent from the custom format.

    Tensor-based version:

    The body region of the loop contains `extract_slice` operations applied to
    every tensor argument of TiledLoopOp.

    The body region must contain exactly one block that terminates with
    `linalg.yield` with the operands resulting from `insert_slice` operations.

    Example:

    ```mlir
    %0 = linalg.tiled_loop (%i) = (%c0) to (%c24) step (%c4)
        ins(%lhs, %rhs : tensor<24x64xi8>, tensor<24x64xi8>)
        outs(%out : tensor<24x64xi8>)
        iterators("parallel")
        distribution("block_x") {
      %lhs_sub = tensor.extract_slice %lhs[%i, 0] [%c4, %c64] [1, 1]
          : tensor<24x64xi8> to tensor<?x?xi8>
      %rhs_sub = tensor.extract_slice %rhs[%i, 0] [%c4, %c64] [1, 1]
          : tensor<24x64xi8> to tensor<?x?xi8>
      %out_sub = tensor.extract_slice %out[%i, 0] [%c4, %c64] [1, 1]
          : tensor<24x64xi8> to tensor<?x?xi8>

      %result_sub = linalg.generic ...

      %result = tensor.insert_slice %result_sub into %out[%i, 0][%c4, %c64][1, 1]
        : tensor<?x?xi8> into tensor<24x64xi8>
      linalg.yield %result : tensor<24x64xi8>
    }
    ```

    MemRef-based version:

    The body region of the loop contains `subview` operations applied to
    every memref argument of TiledLoopOp.

    The body region must contain exactly one block that terminates with
    `linalg.yield` with no operands.

    Example:

    ```mlir
    linalg.tiled_loop (%i) = (%c0) to (%c24) step (%c4)
        ins(%lhs, %rhs : memref<24x64xi8>, memref<24x64xi8>)
        outs(%out : memref<24x64xi8>)
        iterators("parallel")
        distribution("block_x") {
      %lhs_sub = subview %lhs[%i, 0] [%c4, %c64] [1, 1]
          : memref<24x64xi8> to memref<?x?xi8>
      %rhs_sub = subview %rhs[%i, 0] [%c4, %c64] [1, 1]
          : memref<24x64xi8> to memref<?x?xi8>
      %out_sub = subview %out[%i, 0] [%c4, %c64] [1, 1]
          : memref<24x64xi8> to memref<?x?xi8>

      %result_sub = linalg.generic ...
      linalg.yield
    }
    ```
  }];

  let arguments = (ins Variadic<Index>:$lowerBound,
                       Variadic<Index>:$upperBound,
                       Variadic<Index>:$step,
                       Variadic<AnyType>:$inputs,
                       Variadic<AnyShaped>:$outputs,
                       ArrayAttr:$iterator_types,
                       OptionalAttr<ArrayAttr>:$distribution_types);
  let results = (outs Variadic<AnyRankedTensor>:$results);
  let regions = (region SizedRegion<1>:$region);

  let builders = [
    OpBuilder<(ins "ValueRange":$lowerBounds, "ValueRange":$upperBounds,
      "ValueRange":$steps, "ValueRange":$inputs, "ValueRange":$outputs,
      "ArrayAttr":$iteratorTypes, "Optional<ArrayAttr>":$distributionTypes,
      CArg<"function_ref<void (OpBuilder &, Location, /*ivs=*/ValueRange,"
        "/*inputs=*/ValueRange, /*outputs=*/ValueRange)>",
        "nullptr">:$bodyBuilderFn)>,
    OpBuilder<(ins "ValueRange":$lowerBounds, "ValueRange":$upperBounds,
      "ValueRange":$steps, "ValueRange":$inputs, "ValueRange":$outputs,
      "ArrayAttr":$iteratorTypes,
      CArg<"function_ref<void (OpBuilder &, Location, /*ivs=*/ValueRange,"
        "/*inputs=*/ValueRange, /*outputs=*/ValueRange)>",
        "nullptr">:$bodyBuilderFn)>,
  ];

  let extraClassDeclaration = [{
    /// Number of loops
    unsigned getNumLoops() { return step().size(); }

    /// Number of input operands
    unsigned getNumInputs() { return inputs().size(); }

    /// Number of output operands
    unsigned getNumOutputs() { return outputs().size(); }

    /// Number of operands controlling the loop: lbs, ubs, steps
    unsigned getNumControlOperands() { return 3 * getNumLoops(); }

    ValueRange getInductionVars() {
      return getBody()->getArguments().take_front(getNumLoops());
    }
    ValueRange getRegionInputArgs() {
      return getBody()->getArguments().slice(getNumLoops(), inputs().size());
    }
    ValueRange getRegionOutputArgs() {
      return getBody()->getArguments().take_back(outputs().size());
    }

    void setDistributionTypes(Builder& b, ArrayRef<StringRef> types) {
      assert(types.size() == getNumLoops() &&
             "expected distribution type for every dimension");
      distribution_typesAttr(b.getStrArrayAttr(types));
    }

    void setLowerBounds(ValueRange lowerBounds) {
      unsigned numLoops = getNumLoops();
      assert(lowerBounds.size() == numLoops &&
             "expected lower bounds for every loop dimension");
      for (unsigned i = 0; i < numLoops; ++i)
        setOperand(i, lowerBounds[i]);
    }

    void setUpperBounds(ValueRange upperBounds) {
      unsigned numLoops = getNumLoops();
      assert(upperBounds.size() == numLoops &&
             "expected upper bounds for every loop dimension");
      for (unsigned i = 0, pos = numLoops; i < numLoops; ++i, ++pos)
        setOperand(pos, upperBounds[i]);
    }

    void setSteps(ValueRange steps) {
      unsigned numLoops = getNumLoops();
      assert(steps.size() == numLoops &&
             "expected upper bounds for every loop dimension");
      for (unsigned i = 0, pos = 2 * numLoops; i < numLoops; ++i, ++pos)
        setOperand(pos, steps[i]);
    }

    /// Operand that corresponds to the `bbArg` block argument.
    OpOperand& getTiedOperand(BlockArgument& bbArg) {
      return getOperation()->getOpOperand(getNumControlOperands() +
                                          bbArg.getArgNumber() - getNumLoops());
    }

    /// Block argument that corresponds to the `input` or `output` operand.
    BlockArgument getTiedBlockArgument(OpOperand& operand) {
      auto operandIndex = operand.getOperandNumber();
      assert(
          operandIndex >= getNumControlOperands() &&
          operandIndex < getNumOperands() &&
          "tied block arg is defined only for `input` and `output` arguments");
      return getBody()->getArgument(operandIndex - 2 * getNumLoops());
    }

   /// Result that corresponds to the `outputs` argument of tensor type.
   OpResult getTiedOpResult(OpOperand& opOperand) {
      // No result can correspond to a memref argument.
      if (opOperand.get().getType().isa<MemRefType>()) return OpResult();

      // Check whether the operand index is in bounds of `outputs()` arg.
      int operandIndex = opOperand.getOperandNumber();
      int outputIndexStart =
          getNumControlOperands() + inputs().size();
      int outputIndexEnd = outputIndexStart + outputs().size();
      if (operandIndex < outputIndexStart || operandIndex >= outputIndexEnd)
        return OpResult();

      // Count tensor arguments in `outputs` to compute the result index.
      int tensorId = -1;
      for (int i = outputIndexStart; i <= operandIndex; ++i)
        tensorId += getOperand(i).getType().isa<RankedTensorType>();
      return getOperation()->getResult(tensorId);
    }

    /// Append `operand` to the `input` arguments.
    OpOperand& appendInputOperand(OpBuilder& builder, Value operand) {
      int numLoops = getNumLoops();
      int numInputs = getNumInputs();
      int numOutputs = getNumOutputs();

      getOperation()->insertOperands(getNumControlOperands() + numInputs,
                                     operand);
      getBody()->insertArgument(numLoops + numInputs, operand.getType(), 
                                getLoc());
      getOperation()->setAttr(
          TiledLoopOp::getOperandSegmentSizeAttr(),
          builder.getI32VectorAttr(
              {numLoops, numLoops, numLoops, numInputs + 1, numOutputs}));
      return getOperation()->getOpOperand(getNumControlOperands() + numInputs);
    }

    /// Append `operand` to the `output` arguments.
    OpOperand& appendOutputOperand(OpBuilder& builder, Value operand) {
      int numLoops = getNumLoops();
      int numInputs = getNumInputs();
      int numOutputs = getNumOutputs();

      getOperation()->insertOperands(
          getNumControlOperands() + numInputs + numOutputs, operand);
      getBody()->insertArgument(numLoops + numInputs + numOutputs,
                                operand.getType(), getLoc());
      getOperation()->setAttr(
          TiledLoopOp::getOperandSegmentSizeAttr(),
          builder.getI32VectorAttr(
              {numLoops, numLoops, numLoops, numInputs, numOutputs + 1}));
      return getOperation()->getOpOperand(getNumControlOperands() + numInputs +
                                          numOutputs);
    }

    /// Erase `operand` from the `input` or `output` arguments.
    void eraseOperand(OpBuilder& builder, OpOperand& operand) {
      int numInputs = getNumInputs();
      int numLoops = getNumLoops();
      int numOutputs = getNumOutputs();
      int numControlOperands = getNumControlOperands();

      int operandIndex = operand.getOperandNumber();
      assert(operandIndex >= numControlOperands &&
             operandIndex < static_cast<int>(getNumOperands()) &&
             "Can erase only `input` or `output` operand");

      if (operandIndex >= numControlOperands + numInputs)
        --numOutputs;
      else
        --numInputs;

      getOperation()->eraseOperand(operandIndex);
      getBody()->eraseArgument(operandIndex - 2 * numLoops);
      getOperation()->setAttr(
          TiledLoopOp::getOperandSegmentSizeAttr(),
          builder.getI32VectorAttr(
              {numLoops, numLoops, numLoops, numInputs, numOutputs}));
    }

    OpOperand* findInputOperand(Value value) {
      OperandRange::iterator it = llvm::find(inputs(), value);
      if (it == inputs().end()) return nullptr;
      return it.getBase();
    }

    OpOperand* findOutputOperand(Value value) {
      OperandRange::iterator it = llvm::find(outputs(), value);
      if (it == outputs().end()) return nullptr;
      return it.getBase();
    }

    /// Return whether the op has only MemRef input and outputs.
    bool hasBufferSemantics() {
      Operation* op = this->getOperation();
      return op->getNumResults() == 0 &&
             llvm::all_of(op->getOpOperands(), [&](OpOperand & operand) {
               return !operand.get().getType().template isa<ShapedType>() ||
                      operand.get().getType().template isa<MemRefType>();
             });
    }

    /// Return whether the loop dimension is parallel or not.
    bool isParallelDimension(unsigned dim) {
      StringAttr attr = this->iterator_types()[dim].cast<StringAttr>();
      return attr.getValue() == getParallelIteratorTypeName();
    }
  }];

  let hasCanonicalizer = 1;
  let hasFolder = 1;
}

def Linalg_IndexOp : Linalg_Op<"index", [NoSideEffect]>,
    Arguments<(ins Confined<I64Attr, [IntMinValue<0>]>:$dim)>,
    Results<(outs Index:$result)> {
  let summary = "linalg index operation";
  let description = [{
    The `linalg.index` operation returns the iteration index of the immediately
    enclosing linalg structured operation for the iteration dimension `dim`. The
    `dim` attribute specifies the position of the accessed dimension in the
    indexing map domain.

    Example:

    ```mlir
    #map = affine_map<(i, j) -> (i, j)>
    linalg.generic {indexing_maps = [#map, #map],
                    iterator_types = ["parallel", "parallel"]}
      outs(%I, %J : memref<?x?xindex>, memref<?x?xindex>) {
      ^bb0(%arg0 : index, %arg1 : index):
      // Access the outer iteration dimension i
      %i = linalg.index 0 : index
      // Access the inner iteration dimension j
      %j = linalg.index 1 : index
      linalg.yield %i, %j : index, index
    }
    ```

    This may lower to IR resembling:

    ```mlir
    %0 = dim %I, %c0 : memref<?x?xindex>
    %1 = dim %I, %c1 : memref<?x?xindex>
    scf.for %i = %c0 to %0 step %c1 {
      scf.for %j = %c0 to %1 step %c1 {
        store %i, %I[%i, %j] : memref<?x?xindex>
        store %j, %J[%i, %j] : memref<?x?xindex>
      }
    }
    ```
  }];

  let assemblyFormat = [{ $dim attr-dict `:` type($result) }];
}

#endif // LINALG_OPS
