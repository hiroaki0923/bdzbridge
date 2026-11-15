package jp.hiroaki.bdbridge

import androidx.compose.animation.core.AnimationState
import androidx.compose.animation.core.DecayAnimationSpec
import androidx.compose.animation.core.animateDecay
import androidx.compose.animation.splineBasedDecay
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroid
import androidx.compose.foundation.gestures.calculateCentroidSize
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChanged
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.layoutId
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.ScrollAxisRange
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.horizontalScrollAxisRange
import androidx.compose.ui.semantics.scrollBy
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.verticalScrollAxisRange
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** The grid's measures: the iOS grid's in points, here in dp. */
private val ColumnWidth = 132.dp
private val Gutter = 30.dp
private val Header = 54.dp
/** How far a block is drawn inside its column, and inside its time at its foot, so that blocks side by side part. */
private val Inset = 1.dp
/** The least a block is drawn, however short the programme, so that it can be seen and tapped. */
private val Shortest = 10.dp
/** What a long block keeps under its label when the label follows the block's top out of sight. */
private val UnderTheLabel = 34.dp

/**
 * The guide as the iOS guide's grid shows it: time down and the stations across, for one broadcast day, with an hour
 * ruler down the left and the stations across the top that stay where they are while the body moves, a line at the
 * time it is now, and two zoom buttons. One finger moves it either way at once and flings it; two pinch its time axis
 * about the time between them. It stays at the column the reader is at when it goes back to now or changes its scale,
 * which the iOS grid does not.
 *
 * Only the blocks of the columns in view and the hours around them are composed, and a pan or a pinch moves them
 * where they are laid out and drawn (`GridPosition`): nothing goes to Swift as the fingers move.
 */
@Composable
internal fun GuideGrid(guide: Guide, logos: Map<Long, ImageBitmap?>, open: (Programme) -> Unit) {
    val grid = guide.layout
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val position = remember {
        GridPosition(grid.scale.toFloat(), density.density).also { it.show(grid.opening - grid.leadIn) }
    }
    // A new day, or another number of stations: opened again at its own place, as the iOS grid's `task(id:)` is.
    var openedFor by remember { mutableStateOf(grid.key) }
    LaunchedEffect(grid.key) {
        if (grid.key != openedFor) {
            openedFor = grid.key
            position.show(grid.opening - grid.leadIn)
        }
    }
    // 今, or the guide's tab chosen while it shows: back to now, at the column the reader is at.
    var answered by remember { mutableLongStateOf(guide.nowRequests) }
    LaunchedEffect(guide.nowRequests) {
        if (guide.nowRequests != answered) {
            answered = guide.nowRequests
            position.show((if (grid.now >= 0) grid.now else 0.0) - grid.leadIn)
        }
    }
    // Another broadcasting type has other stations: from the first of them.
    var type by remember { mutableStateOf(guide.broadcasting) }
    LaunchedEffect(guide.broadcasting) {
        if (guide.broadcasting != type) {
            type = guide.broadcasting
            position.moveTo(0f, position.y)
        }
    }
    // A scale the model has kept that the grid does not show yet -- a zoom button's -- shown with the time in the
    // middle of the body held where it is. What a pinch kept is what the grid shows already.
    var kept by remember { mutableDoubleStateOf(grid.scale) }
    LaunchedEffect(grid.scale) {
        if (grid.scale != kept) {
            kept = grid.scale
            if (!position.touching) position.zoom(grid.scale.toFloat(), position.height / 2)
        }
    }
    val colors = MaterialTheme.colorScheme
    BoxWithConstraints(Modifier.fillMaxSize().clipToBounds()) {
        val gutter = with(density) { Gutter.toPx() }
        val header = with(density) { Header.toPx() }
        val columnWidth = with(density) { ColumnWidth.toPx() }
        val width = constraints.maxWidth - gutter
        val height = constraints.maxHeight - header
        // Told here, before the window below is read, rather than after the composition, so that the first frame is
        // composed with what is in view: the window is all the composition reads of the position.
        position.fit(width, height, grid.columns.size, columnWidth, grid.minutes)
        val window by remember { derivedStateOf { position.window() } }
        Box(Modifier.fillMaxSize().background(colors.surface)
                .panAndPinch(position, header, grid.smallest.toFloat(), grid.largest.toFloat(), scope)
                .scrollActions(position)) {
            Body(grid, window, position, open, Modifier.padding(start = Gutter, top = Header).fillMaxSize())
            HourRuler(grid, position, Modifier.padding(top = Header).width(Gutter).fillMaxHeight())
            StationRuler(grid, window, logos, position, Modifier.padding(start = Gutter).fillMaxWidth().height(Header))
            Box(Modifier.size(Gutter, Header).background(colors.surfaceContainer))
            ZoomButtons(grid, Modifier.align(Alignment.BottomEnd))
        }
    }
}

/**
 * Where the reader is in the grid: how far the body has been moved, in pixels from the first column and the day's
 * first minute, and the scale it is drawn at, in dp a minute. It is snapshot state that the grid reads where it is
 * laid out and drawn, and for what is composed only through `window`, which moves at a column's or an hour's edge, so
 * that a pan or a pinch lays out and draws the grid again without composing it again.
 */
@Stable
private class GridPosition(scale: Float, private val density: Float) {
    var x by mutableFloatStateOf(0f)
        private set
    var y by mutableFloatStateOf(0f)
        private set
    var scale by mutableFloatStateOf(scale)
        private set
    /** The body's size, and what it holds. */
    var width by mutableFloatStateOf(0f)
        private set
    var height by mutableFloatStateOf(0f)
        private set
    private var columns by mutableIntStateOf(0)
    private var columnWidth = 1f
    private var minutes = 1440f
    /** Whether fingers are on the grid, when a scale from the model waits for them. */
    var touching = false
    var fling: Job? = null

    val perMinute: Float get() = scale * density
    val maxX: Float get() = max(0f, columns * columnWidth - width)
    val maxY: Float get() = max(0f, minutes * perMinute - height)

    fun fit(width: Float, height: Float, columns: Int, columnWidth: Float, minutes: Double) {
        this.columnWidth = columnWidth
        this.minutes = minutes.toFloat()
        this.columns = columns
        this.width = width
        this.height = height
        moveTo(x, y)
    }

    /** Moves the body, held inside what it holds; whether it moved at all. */
    fun moveTo(toX: Float, toY: Float): Boolean {
        val newX = toX.coerceIn(0f, maxX)
        val newY = toY.coerceIn(0f, maxY)
        val moved = newX != x || newY != y
        x = newX
        y = newY
        return moved
    }

    fun panBy(dx: Float, dy: Float) = moveTo(x + dx, y + dy)

    /** Puts a minute of the day at the body's top, at the column the reader is at. */
    fun show(minute: Double) = moveTo(x, (minute * perMinute).toFloat())

    /** Draws the grid at another scale with the time `focus` pixels below the body's top held where it is. */
    fun zoom(to: Float, focus: Float) {
        val minute = (y + focus) / perMinute
        scale = to
        moveTo(x, minute * perMinute - focus)
    }

    /** The columns and the stretch of the day to compose: what is in view, and a column and an hour either side. */
    fun window(): Window {
        if (columns == 0) return Window(0, -1, 0.0, 0.0)
        val first = (floor(x / columnWidth).toInt() - 1).coerceIn(0, columns - 1)
        val last = (floor((x + width) / columnWidth).toInt() + 1).coerceIn(0, columns - 1)
        val firstHour = floor(y / perMinute / 60).toInt() - 1
        val lastHour = floor((y + height) / perMinute / 60).toInt() + 1
        return Window(first, last, firstHour * 60.0, (lastHour + 1) * 60.0)
    }
}

private data class Window(val firstColumn: Int, val lastColumn: Int, val fromMinute: Double, val toMinute: Double)

/**
 * The grid's one gesture handler: a finger moves it either way at once and flings it when let go moving, and two
 * pinch its time axis about the time between them, which stays under them. A tap is left to the block under it,
 * since nothing is taken until the fingers have moved past the touch slop; but a touch that stops a fling is taken
 * before the block sees it, so that it opens nothing. The scale a pinch leaves is kept when the fingers have gone.
 */
private fun Modifier.panAndPinch(position: GridPosition, header: Float, smallest: Float, largest: Float,
                                 scope: CoroutineScope): Modifier = pointerInput(position, smallest, largest) {
    val decay = splineBasedDecay<Float>(this)
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        if (position.fling?.isActive == true) down.consume()
        position.fling?.cancel()
        position.touching = true
        val tracker = VelocityTracker()
        // The fingers' movement added up, which the fling's speed is measured on: a finger lifted or put down
        // changes where they are, not how far they have moved.
        var moved = Offset.Zero
        var zoomed = 1f
        var slop = Offset.Zero
        var past = false
        var pinched = false
        try {
            while (true) {
                val event = awaitPointerEvent()
                if (event.changes.none { it.pressed }) break
                val zoom = event.calculateZoom()
                val pan = event.calculatePan()
                if (!past) {
                    zoomed *= zoom
                    slop += pan
                    val spread = abs(1 - zoomed) * event.calculateCentroidSize(useCurrent = false)
                    past = spread > viewConfiguration.touchSlop || slop.getDistance() > viewConfiguration.touchSlop
                }
                if (past) {
                    if (zoom != 1f) {
                        pinched = true
                        val between = event.calculateCentroid(useCurrent = false).y - header
                        position.zoom((position.scale * zoom).coerceIn(smallest, largest), between)
                    }
                    position.panBy(-pan.x, -pan.y)
                    event.changes.forEach { if (it.positionChanged()) it.consume() }
                }
                moved += pan
                tracker.addPosition(event.changes.first().uptimeMillis, moved)
            }
        } finally {
            position.touching = false
        }
        if (pinched) {
            RecBridge.keepScale(position.scale.toDouble())
        } else if (past) {
            val most = viewConfiguration.maximumFlingVelocity
            position.fling = scope.fling(position, tracker.calculateVelocity(Velocity(most, most)), decay)
        }
    }
}

/**
 * Carries the body on in a straight line in the direction it was flung, slowing as a list does, until it comes to a
 * stop or to the edge both ways. One decay along the line rather than one each way, which would bend it.
 */
private fun CoroutineScope.fling(position: GridPosition, velocity: Velocity, decay: DecayAnimationSpec<Float>): Job? {
    val speed = hypot(velocity.x, velocity.y)
    if (speed == 0f) return null
    val dx = -velocity.x / speed
    val dy = -velocity.y / speed
    val fromX = position.x
    val fromY = position.y
    return launch {
        AnimationState(0f, speed).animateDecay(decay) {
            if (!position.moveTo(fromX + dx * value, fromY + dy * value)) cancelAnimation()
        }
    }
}

/** The grid moved by a screen reader's scroll actions, which a gesture of the screen reader's own cannot reach. */
private fun Modifier.scrollActions(position: GridPosition) = semantics {
    horizontalScrollAxisRange = ScrollAxisRange(value = { position.x }, maxValue = { position.maxX })
    verticalScrollAxisRange = ScrollAxisRange(value = { position.y }, maxValue = { position.maxY })
    scrollBy { dx, dy -> position.panBy(dx, dy) }
}

/** Where a block goes: its column, and its time in the day in minutes. */
private class Spot(val column: Int, val top: Double, val length: Double)

/**
 * The programmes, the hours' lines under them and the line at now over them. A block is measured as the scale says,
 * so a pinch measures the blocks again, and placed as the position says, so a pan only places them.
 */
@Composable
private fun Body(grid: GridDay, window: Window, position: GridPosition, open: (Programme) -> Unit, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    val hourLine = colors.outlineVariant.copy(alpha = 0.5f)
    val nowLine = colors.error
    Layout(
        content = {
            for (index in window.firstColumn..window.lastColumn) {
                for (block in grid.columns[index].blocks) {
                    val end = block.top + max(0.0, block.length)
                    if (block.top >= window.toMinute || end <= window.fromMinute) continue
                    key(block.row.id) {
                        Block(block, position, Modifier.layoutId(Spot(index, block.top, block.length))) {
                            open(block.row)
                        }
                    }
                }
            }
        },
        modifier = modifier.clipToBounds()
            .drawBehind {
                for (hour in grid.hours.indices) {
                    val lineY = hour * 60 * position.perMinute - position.y
                    if (lineY in 0f..size.height) drawLine(hourLine, Offset(0f, lineY), Offset(size.width, lineY), 1f)
                }
            }
            .drawWithContent {
                drawContent()
                if (grid.now >= 0) {
                    val lineY = (grid.now * position.perMinute).toFloat() - position.y
                    val thickness = 2.dp.toPx()
                    drawRect(nowLine, Offset(0f, lineY - thickness / 2), Size(size.width, thickness))
                }
            },
    ) { measurables, constraints ->
        val perMinute = position.perMinute
        val columnWidth = ColumnWidth.toPx()
        val inset = Inset.toPx()
        val blockWidth = (columnWidth - 2 * inset).roundToInt()
        val placed = measurables.map { measurable ->
            val spot = measurable.layoutId as Spot
            val blockHeight = max(Shortest.toPx(), (spot.length * perMinute).toFloat() - 2 * inset)
            measurable.measure(Constraints.fixed(blockWidth, blockHeight.roundToInt())) to spot
        }
        layout(constraints.maxWidth, constraints.maxHeight) {
            val x = position.x
            val y = position.y
            for ((placeable, spot) in placed) {
                placeable.place((spot.column * columnWidth + inset - x).roundToInt(),
                                ((spot.top * perMinute).toFloat() - y).roundToInt())
            }
        }
    }
}

/**
 * One programme, as the iOS block says it: the time, the mark and the title, tinted for a reservation, with its
 * genre's colour down its side; what is on air is shaded down to now, and what is over is dimmed. A screen reader
 * reads it as one sentence, the model's.
 */
@Composable
private fun Block(block: GridBlock, position: GridPosition, modifier: Modifier, open: () -> Unit) {
    val colors = MaterialTheme.colorScheme
    val marks = LocalMarks.current
    val accent = if (block.accent >= 0) Color(0xFF000000 or block.accent) else colors.outlineVariant
    val ground = when {
        block.held -> marks.reserved
        block.waiting -> lerp(colors.surfaceContainerHigh, marks.reserved, 0.5f)
        else -> colors.surfaceContainerHigh
    }
    val bar = if (block.onAir) 4.dp else 3.dp
    val row = block.row
    val label = buildAnnotatedString {
        withStyle(SpanStyle(color = colors.onSurfaceVariant)) { append(row.time) }
        if (row.mark.isNotEmpty()) {
            append(" ")
            withStyle(SpanStyle(color = if (row.markIsRed) colors.error else marks.onReserved,
                                fontWeight = FontWeight.SemiBold)) { append(row.mark) }
        }
        append(" ")
        withStyle(SpanStyle(fontWeight = if (block.onAir) FontWeight.SemiBold else FontWeight.Normal)) {
            append(row.title)
        }
    }
    Box(modifier.alpha(if (block.ended) 0.5f else 1f)
            .clip(MaterialTheme.shapes.extraSmall)
            .background(ground)
            .drawBehind {
                // The part that has gone, which meets the line at now.
                if (block.onAir) {
                    drawRect(accent.copy(alpha = 0.16f), size = Size(size.width, size.height * block.elapsed.toFloat()))
                }
                drawRect(accent, size = Size(bar.toPx(), size.height))
            }
            .clickable(role = Role.Button, onClick = open)
            .clearAndSetSemantics { contentDescription = block.spoken }) {
        Text(label, style = MaterialTheme.typography.labelSmall, overflow = TextOverflow.Ellipsis,
             modifier = Modifier.followingTheTop(block, position).padding(start = bar + 3.dp, top = 2.dp, end = 4.dp))
    }
}

/**
 * Keeps a long programme's label in view while its block's top is out of sight above the body, as the iOS grid does:
 * moved down by what is hidden, but never so far that less than `UnderTheLabel` of the block is left for it. Worked
 * out where the label is laid out, from the position, so that a pan moves it without composing the block again; the
 * height left to it is what the text ellipsizes at.
 */
private fun Modifier.followingTheTop(block: GridBlock, position: GridPosition) = layout { measurable, constraints ->
    val height = constraints.maxHeight
    val hidden = position.y - (block.top * position.perMinute).toFloat()
    val offset = hidden.coerceIn(0f, max(0f, height - UnderTheLabel.toPx())).roundToInt()
    val placeable = measurable.measure(constraints.copy(minHeight = 0, maxHeight = height - offset))
    layout(constraints.maxWidth, height) { placeable.place(0, offset) }
}

/** The hours down the left, from four, moved with the body. */
@Composable
private fun HourRuler(grid: GridDay, position: GridPosition, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    Layout(
        content = {
            for (hour in grid.hours) {
                Text(hour, style = MaterialTheme.typography.labelSmall, color = colors.onSurfaceVariant)
            }
        },
        modifier = modifier.clipToBounds().background(colors.surface).drawWithContent {
            drawContent()
            drawLine(colors.outlineVariant, Offset(size.width, 0f), Offset(size.width, size.height), 1f)
        },
    ) { measurables, constraints ->
        val labels = measurables.map { it.measure(Constraints()) }
        layout(constraints.maxWidth, constraints.maxHeight) {
            val perMinute = position.perMinute
            val y = position.y
            val below = 2.dp.roundToPx()
            labels.forEachIndexed { index, label ->
                label.place((constraints.maxWidth - label.width) / 2, (index * 60 * perMinute - y).roundToInt() + below)
            }
        }
    }
}

/** The stations across the top, each with its logo, moved with the body: those in view and one either side. */
@Composable
private fun StationRuler(grid: GridDay, window: Window, logos: Map<Long, ImageBitmap?>, position: GridPosition,
                         modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    Layout(
        content = {
            for (index in window.firstColumn..window.lastColumn) {
                val column = grid.columns[index]
                key(column.serviceID) {
                    Column(Modifier.layoutId(index)
                               .drawBehind { drawLine(colors.outlineVariant, Offset.Zero, Offset(0f, size.height), 1f) }
                               .padding(horizontal = 4.dp),
                           verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically),
                           horizontalAlignment = Alignment.CenterHorizontally) {
                        logos[column.serviceID]?.let {
                            Image(it, contentDescription = null, Modifier.size(36.dp, 18.dp))
                        }
                        Text(column.name, style = MaterialTheme.typography.labelSmall, maxLines = 1,
                             overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        },
        modifier = modifier.clipToBounds().background(colors.surfaceContainer).drawWithContent {
            drawContent()
            drawLine(colors.outlineVariant, Offset(0f, size.height), Offset(size.width, size.height), 1f)
        },
    ) { measurables, constraints ->
        val columnWidth = ColumnWidth.toPx()
        val cells = measurables.map {
            it.measure(Constraints.fixed(columnWidth.roundToInt(), constraints.maxHeight)) to it.layoutId as Int
        }
        layout(constraints.maxWidth, constraints.maxHeight) {
            val x = position.x
            for ((cell, index) in cells) cell.place((index * columnWidth - x).roundToInt(), 0)
        }
    }
}

/** 表示を縮小 and 表示を拡大: a step of the model's each way, held at its bounds, with the time in the middle held still. */
@Composable
private fun ZoomButtons(grid: GridDay, modifier: Modifier) {
    Row(modifier.padding(12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilledTonalIconButton(onClick = { RecBridge.zoom(growing = false) }, enabled = grid.canShrink,
                              modifier = Modifier.shadow(2.dp, CircleShape)) {
            Icon(Icons.Default.Remove, contentDescription = grid.shrinkLabel)
        }
        FilledTonalIconButton(onClick = { RecBridge.zoom(growing = true) }, enabled = grid.canGrow,
                              modifier = Modifier.shadow(2.dp, CircleShape)) {
            Icon(Icons.Default.Add, contentDescription = grid.growLabel)
        }
    }
}
